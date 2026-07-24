unit MeshTransport;
{
  Transport layer for the Meshtastic client.

  ITransport hides *how* we talk to the radio. The client only ever exchanges
  whole protobufs: it Sends one ToRadio protobuf and receives whole FromRadio
  protobufs via TryGetPacket.

  Two wire formats exist in Meshtastic:
    * Stream transports (USB serial, TCP): every protobuf is prefixed with a
      4-byte header  0x94 0xC3  <len-hi> <len-lo>  (length big-endian, <= 512).
      Bytes that are not a valid frame are the device's debug console output.
    * BLE: no header; each GATT characteristic read/write is one whole protobuf.
      (see meshble.pas)

  TSerialTransport implements the stream format over a serial port using the
  RTL 'Serial' unit, which works on both Unix and Windows. TTcpTransport
  implements the same stream format over a TCP connection to a radio on the
  network (WiFi-capable devices listen on port 4403). In both, a background
  thread reads bytes, reassembles frames, and pushes complete packets / debug
  lines into thread-safe queues that the main thread drains.
}
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Serial, Sockets, SSockets
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

type
  ITransport = interface
    ['{4B0F3B2A-6C11-4E7A-9E2D-2E1A6C7D9F01}']
    procedure Send(const b: TBytes);
    function TryGetPacket(out b: TBytes): Boolean;
    function TryGetDebug(out s: string): Boolean;
    function IsOpen: Boolean;
    procedure Close;
  end;

  { Thread-safe FIFO of byte packets (stored as RawByteString). }
  TByteQueue = class
  private
    FLock: TCriticalSection;
    FItems: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(const b: TBytes);
    function Pop(out b: TBytes): Boolean;
  end;

  { Frames outgoing packets and de-frames the incoming byte stream. }
  TStreamFramer = class
  private
    FBuf: TBytes;
    FDbgLine: string;
    FPackets: TByteQueue;
    FDebugLock: TCriticalSection;
    FDebug: TStringList;
    procedure EmitDebugChar(c: Byte);
    procedure FlushDebug;
  public
    constructor Create(APackets: TByteQueue);
    destructor Destroy; override;
    class function Frame(const b: TBytes): TBytes;
    procedure Feed(const chunk; count: Integer);
    function PopDebug(out s: string): Boolean;
  end;

  { Base class for stream transports; subclasses implement the raw byte I/O. }
  TStreamTransportBase = class(TInterfacedObject, ITransport)
  private
    type
      TReaderThread = class(TThread)
      private
        FOwner: TStreamTransportBase;
      protected
        procedure Execute; override;
      public
        constructor Create(AOwner: TStreamTransportBase);
      end;
  private
    FPackets: TByteQueue;
    FFramer: TStreamFramer;
    FReader: TReaderThread;
    FStop: Boolean;
    FOpen: Boolean;
  protected
    { To be provided by subclasses. }
    function RawRead(var buf; count: Integer): Integer; virtual; abstract;
    function RawWrite(const buf; count: Integer): Integer; virtual; abstract;
    procedure RawClose; virtual; abstract;
    procedure StartReader;
  public
    constructor Create;
    destructor Destroy; override;
    { ITransport }
    procedure Send(const b: TBytes);
    function TryGetPacket(out b: TBytes): Boolean;
    function TryGetDebug(out s: string): Boolean;
    function IsOpen: Boolean;
    procedure Close;
  end;

  TSerialTransport = class(TStreamTransportBase)
  private
    FHandle: TSerialHandle;
  protected
    function RawRead(var buf; count: Integer): Integer; override;
    function RawWrite(const buf; count: Integer): Integer; override;
    procedure RawClose; override;
  public
    constructor Create(const APort: string; ABaud: LongInt = 115200);
  end;

  TTcpTransport = class(TStreamTransportBase)
  private
    FSock: TInetSocket;
  protected
    function RawRead(var buf; count: Integer): Integer; override;
    function RawWrite(const buf; count: Integer): Integer; override;
    procedure RawClose; override;
  public
    constructor Create(const AHost: string; APort: Word = 4403);
    destructor Destroy; override;
  end;

implementation

{ ======================= TByteQueue ======================= }

constructor TByteQueue.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TStringList.Create;
end;

destructor TByteQueue.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TByteQueue.Push(const b: TBytes);
var
  rb: RawByteString;
begin
  SetLength(rb, Length(b));
  if Length(b) > 0 then
    Move(b[0], rb[1], Length(b));
  FLock.Enter;
  try
    FItems.Add(rb);
  finally
    FLock.Leave;
  end;
end;

function TByteQueue.Pop(out b: TBytes): Boolean;
var
  rb: RawByteString;
begin
  b := nil;
  Result := False;
  FLock.Enter;
  try
    if FItems.Count > 0 then
    begin
      rb := FItems[0];
      FItems.Delete(0);
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
  if Result then
  begin
    SetLength(b, Length(rb));
    if Length(rb) > 0 then
      Move(rb[1], b[0], Length(rb));
  end;
end;

{ ======================= TStreamFramer ======================= }

constructor TStreamFramer.Create(APackets: TByteQueue);
begin
  inherited Create;
  FPackets := APackets;
  FDebugLock := TCriticalSection.Create;
  FDebug := TStringList.Create;
  FBuf := nil;
  FDbgLine := '';
end;

destructor TStreamFramer.Destroy;
begin
  FlushDebug;
  FDebug.Free;
  FDebugLock.Free;
  inherited Destroy;
end;

class function TStreamFramer.Frame(const b: TBytes): TBytes;
var
  n: Integer;
begin
  n := Length(b);
  Result := nil;
  SetLength(Result, n + 4);
  Result[0] := $94;
  Result[1] := $C3;
  Result[2] := Byte((n shr 8) and $FF);
  Result[3] := Byte(n and $FF);
  if n > 0 then
    Move(b[0], Result[4], n);
end;

procedure TStreamFramer.EmitDebugChar(c: Byte);
begin
  if (c = 10) or (c = 13) then
    FlushDebug
  else if (c >= 32) and (c < 127) then
    FDbgLine := FDbgLine + Chr(c)
  else
    FDbgLine := FDbgLine + '.';
end;

procedure TStreamFramer.FlushDebug;
begin
  if FDbgLine <> '' then
  begin
    FDebugLock.Enter;
    try
      FDebug.Add(FDbgLine);
    finally
      FDebugLock.Leave;
    end;
    FDbgLine := '';
  end;
end;

function TStreamFramer.PopDebug(out s: string): Boolean;
begin
  s := '';
  Result := False;
  FDebugLock.Enter;
  try
    if FDebug.Count > 0 then
    begin
      s := FDebug[0];
      FDebug.Delete(0);
      Result := True;
    end;
  finally
    FDebugLock.Leave;
  end;
end;

procedure TStreamFramer.Feed(const chunk; count: Integer);
var
  oldLen, i, pos, plen: Integer;
  pkt: TBytes;
begin
  if count <= 0 then Exit;

  { append chunk to FBuf }
  oldLen := Length(FBuf);
  SetLength(FBuf, oldLen + count);
  Move(chunk, FBuf[oldLen], count);

  pos := 0;
  while pos < Length(FBuf) do
  begin
    if FBuf[pos] <> $94 then
    begin
      EmitDebugChar(FBuf[pos]);
      Inc(pos);
      Continue;
    end;
    { potential header start }
    if pos + 1 >= Length(FBuf) then
      Break; { need more bytes to see second magic byte }
    if FBuf[pos + 1] <> $C3 then
    begin
      EmitDebugChar(FBuf[pos]); { the 0x94 was not a header }
      Inc(pos);
      Continue;
    end;
    if pos + 4 > Length(FBuf) then
      Break; { need the 2 length bytes }
    plen := (Integer(FBuf[pos + 2]) shl 8) or Integer(FBuf[pos + 3]);
    if plen > 512 then
    begin
      { corrupt / not really a frame: drop the magic byte and resync }
      EmitDebugChar(FBuf[pos]);
      Inc(pos);
      Continue;
    end;
    if pos + 4 + plen > Length(FBuf) then
      Break; { wait for the whole body }
    SetLength(pkt, plen);
    if plen > 0 then
      Move(FBuf[pos + 4], pkt[0], plen);
    FPackets.Push(pkt);
    Inc(pos, 4 + plen);
  end;

  { compact: keep only unconsumed tail }
  if pos > 0 then
  begin
    if pos < Length(FBuf) then
    begin
      for i := 0 to Length(FBuf) - pos - 1 do
        FBuf[i] := FBuf[pos + i];
      SetLength(FBuf, Length(FBuf) - pos);
    end
    else
      SetLength(FBuf, 0);
  end;
end;

{ ================= TStreamTransportBase.TReaderThread ================= }

constructor TStreamTransportBase.TReaderThread.Create(AOwner: TStreamTransportBase);
begin
  FOwner := AOwner;
  inherited Create(False);   { start immediately }
  FreeOnTerminate := False;
end;

procedure TStreamTransportBase.TReaderThread.Execute;
var
  buf: array[0..1023] of Byte;
  n: Integer;
  {$IFDEF UNIX}errn: LongInt;{$ENDIF}
begin
  while not Terminated and not FOwner.FStop do
  begin
    n := FOwner.RawRead(buf, SizeOf(buf));
    if n > 0 then
      FOwner.FFramer.Feed(buf, n)
    else if n = 0 then
      Sleep(5)
    else
    begin
      { A negative return is not always fatal: a blocking read interrupted by a
        signal returns EINTR, and a non-blocking read with no data yet returns
        EAGAIN. Retry those instead of killing the reader (this is why a BLE-
        enabled build, which links libdbus and changes the signal environment,
        could otherwise go silent on the serial path). Only a real error stops us. }
      {$IFDEF UNIX}
      errn := fpgeterrno;
      if (errn = ESysEINTR) or (errn = ESysEAGAIN) then
        Sleep(5)
      else
        Break;
      {$ELSE}
      Break;
      {$ENDIF}
    end;
  end;
end;

{ ======================= TStreamTransportBase ======================= }

constructor TStreamTransportBase.Create;
begin
  inherited Create;
  FPackets := TByteQueue.Create;
  FFramer := TStreamFramer.Create(FPackets);
  FStop := False;
  FOpen := True;
  FReader := nil;
end;

procedure TStreamTransportBase.StartReader;
begin
  if FReader = nil then
    FReader := TReaderThread.Create(Self);
end;

destructor TStreamTransportBase.Destroy;
begin
  Close;
  FFramer.Free;
  FPackets.Free;
  inherited Destroy;
end;

procedure TStreamTransportBase.Send(const b: TBytes);
var
  framed: TBytes;
begin
  if not FOpen then Exit;
  framed := TStreamFramer.Frame(b);
  RawWrite(framed[0], Length(framed));
end;

function TStreamTransportBase.TryGetPacket(out b: TBytes): Boolean;
begin
  Result := FPackets.Pop(b);
end;

function TStreamTransportBase.TryGetDebug(out s: string): Boolean;
begin
  Result := FFramer.PopDebug(s);
end;

function TStreamTransportBase.IsOpen: Boolean;
begin
  Result := FOpen;
end;

procedure TStreamTransportBase.Close;
begin
  if not FOpen then Exit;
  FOpen := False;
  FStop := True;
  RawClose;                { unblocks a pending read }
  if FReader <> nil then
  begin
    FReader.WaitFor;
    FReader.Free;
    FReader := nil;
  end;
end;

{ ======================= TSerialTransport ======================= }

constructor TSerialTransport.Create(const APort: string; ABaud: LongInt);
begin
  inherited Create;
  FHandle := SerOpen(APort);
  {$IFDEF UNIX}
  if FHandle < 0 then
  {$ELSE}
  if PtrInt(FHandle) <= 0 then
  {$ENDIF}
    raise Exception.CreateFmt('Could not open serial port "%s"', [APort]);
  SerSetParams(FHandle, ABaud, 8, NoneParity, 1, []);
  StartReader;
end;

function TSerialTransport.RawRead(var buf; count: Integer): Integer;
begin
  Result := SerRead(FHandle, buf, count);
end;

function TSerialTransport.RawWrite(const buf; count: Integer): Integer;
begin
  Result := SerWrite(FHandle, buf, count);
end;

procedure TSerialTransport.RawClose;
begin
  SerClose(FHandle);
end;

{ ======================= TTcpTransport ======================= }

constructor TTcpTransport.Create(const AHost: string; APort: Word);
begin
  inherited Create;
  FSock := TInetSocket.Create(AHost, APort);  { raises ESocketError on failure }
  StartReader;
end;

destructor TTcpTransport.Destroy;
begin
  { inherited Close joins the reader thread, which may be mid-read on FSock,
    so the socket object must outlive it }
  inherited Destroy;
  FSock.Free;
end;

function TTcpTransport.RawRead(var buf; count: Integer): Integer;
begin
  Result := FSock.Read(buf, count);
  if Result = 0 then
  begin
    { A zero-byte TCP read means the peer closed the connection - fatal, not
      "no data yet". Clear errno so the reader thread does not mistake it for
      a stale EINTR/EAGAIN and retry forever. }
    {$IFDEF UNIX}fpseterrno(0);{$ENDIF}
    Result := -1;
  end;
end;

function TTcpTransport.RawWrite(const buf; count: Integer): Integer;
begin
  Result := FSock.Write(buf, count);
end;

procedure TTcpTransport.RawClose;
begin
  { shutdown (not close) unblocks the reader's pending recv; the socket is
    freed in the destructor once the thread has joined }
  if FSock <> nil then
    fpshutdown(FSock.Handle, SHUT_RDWR);
end;

end.
