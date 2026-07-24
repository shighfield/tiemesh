unit MeshProto;
{
  MeshProto - minimal Protocol Buffers (proto3) wire-format codec, plus the
  small subset of Meshtastic message encoders/decoders this client needs.

  Nothing here depends on a .proto compiler: we hand-roll only the fields we
  use, addressed by field number. All field numbers below were taken from the
  Meshtastic protobuf definitions (mesh.proto / portnums.proto / channel.proto).

  Wire types:  0 = varint, 1 = i64, 2 = length-delimited, 5 = i32
  NOTE: fixed32 / float / i32 are little-endian on the wire. This unit assumes
  a little-endian host CPU (x86 / ARM), which covers the supported targets.
}
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

const
  { PortNum values (portnums.proto) }
  PORT_TEXT_MESSAGE_APP = 1;
  PORT_POSITION_APP     = 3;
  PORT_NODEINFO_APP     = 4;
  PORT_ROUTING_APP      = 5;
  PORT_TELEMETRY_APP    = 67;
  PORT_TRACEROUTE_APP   = 70;

  { Channel.Role (channel.proto) }
  CH_ROLE_DISABLED  = 0;
  CH_ROLE_PRIMARY   = 1;
  CH_ROLE_SECONDARY = 2;

  BROADCAST_ADDR = LongWord($FFFFFFFF);

type
  { ---- low level protobuf writer ---- }
  TPbWriter = class
  private
    FStream: TMemoryStream;
  public
    constructor Create;
    destructor Destroy; override;
    procedure WriteVarint(v: QWord);
    procedure WriteTag(field, wire: Integer);
    procedure WriteVarintField(field: Integer; v: QWord);
    procedure WriteBoolField(field: Integer; v: Boolean);
    procedure WriteFixed32Field(field: Integer; v: LongWord);
    procedure WriteBytesField(field: Integer; const b: TBytes);
    procedure WriteStringField(field: Integer; const s: string);
    procedure WriteMessageField(field: Integer; const msg: TBytes);
    function ToBytes: TBytes;
  end;

  { ---- low level protobuf reader over a byte slice ---- }
  TPbReader = class
  private
    FData: TBytes;
    FPos: Integer;
    FEnd: Integer;
  public
    constructor Create(const AData: TBytes); overload;
    constructor Create(const AData: TBytes; AStart, ALen: Integer); overload;
    function Eof: Boolean;
    function ReadVarint: QWord;
    function ReadTag(out field, wire: Integer): Boolean;
    procedure SkipField(wire: Integer);
    function ReadFixed32: LongWord;
    function ReadFloat: Single;
    function ReadLenBytes: TBytes;
    function ReadLenString: string;
    { For embedded messages: returns the byte range without copying. }
    procedure ReadLenSlice(out AStart, ALen: Integer);
  end;

  { ---- Meshtastic message records (only fields we consume) ---- }
  TMeshUser = record
    Id: string;
    LongName: string;
    ShortName: string;
    HwModel: Integer;
    HasKey: Boolean;
  end;

  TMeshNode = record
    Num: LongWord;
    HasUser: Boolean;
    User: TMeshUser;
    Snr: Single;
    LastHeard: LongWord;
    HasHops: Boolean;
    HopsAway: Integer;
    HasPos: Boolean;
    LatI, LonI: LongInt;
    HasBattery: Boolean;
    Battery: Integer;
    IsFavorite: Boolean;
  end;

  TChannelInfo = record
    Index: Integer;
    Role: Integer;
    Name: string;
  end;

  TDataMsg = record
    Portnum: Integer;
    Payload: TBytes;
    WantResponse: Boolean;
    Dest, Source, RequestId, ReplyId: LongWord;
  end;

  TMeshPacket = record
    FromNum, ToNum: LongWord;
    Channel: Integer;
    Id: LongWord;
    RxTime: LongWord;
    RxSnr: Single;
    RxRssi: LongInt;
    HopLimit, HopStart: Integer;
    WantAck: Boolean;
    HasDecoded: Boolean;
    Decoded: TDataMsg;
    Encrypted: Boolean;
  end;

  TFromRadioKind = (frUnknown, frPacket, frMyInfo, frNodeInfo,
                    frConfigComplete, frChannel, frLogRecord, frRebooted);

  TFromRadio = record
    Kind: TFromRadioKind;
    Id: LongWord;
    Packet: TMeshPacket;
    MyNodeNum: LongWord;
    Node: TMeshNode;
    Channel: TChannelInfo;
    ConfigCompleteId: LongWord;
    LogText: string;
  end;

  TRouteDiscovery = record
    Route: array of LongWord;      { node nums along the way (towards) }
    SnrTowards: array of LongInt;  { SNR * 4 }
    RouteBack: array of LongWord;
    SnrBack: array of LongInt;
  end;

  TDeviceMetrics = record
    HasBattery: Boolean;  Battery: LongWord;   { 0-100, >100 = powered }
    HasVoltage: Boolean;  Voltage: Single;
    HasChanUtil: Boolean; ChanUtil: Single;
    HasAirTx: Boolean;    AirTx: Single;
    HasUptime: Boolean;   Uptime: LongWord;    { seconds }
  end;

  TEnvMetrics = record
    HasTemp: Boolean;     Temp: Single;
    HasHumidity: Boolean; Humidity: Single;
    HasPressure: Boolean; Pressure: Single;
    HasGas: Boolean;      Gas: Single;
  end;

  TTelemetry = record
    HasDevice: Boolean; Device: TDeviceMetrics;
    HasEnv: Boolean;    Env: TEnvMetrics;
  end;

{ ---- encoders (return a complete ToRadio protobuf) ---- }
function EncodeWantConfig(nonce: LongWord): TBytes;
function EncodeDisconnect: TBytes;
function EncodeHeartbeat: TBytes;
function EncodeTextPacket(dest: LongWord; channelIndex: Integer;
  wantAck: Boolean; id: LongWord; const text: string): TBytes;
function EncodeTraceroutePacket(dest: LongWord; channelIndex, hopLimit: Integer;
  id: LongWord): TBytes;
function EncodeTelemetryPacket(dest: LongWord; channelIndex: Integer;
  id: LongWord): TBytes;
function EncodeNodeInfoPacket(dest: LongWord; channelIndex: Integer;
  id: LongWord; const myId: string): TBytes;

{ ---- decoders ---- }
function DecodeFromRadio(const b: TBytes): TFromRadio;
function DecodeRouteDiscovery(const b: TBytes): TRouteDiscovery;
function DecodeTelemetry(const b: TBytes): TTelemetry;
function DecodeUser(const data: TBytes; s, l: Integer): TMeshUser;

{ ---- helpers ---- }
function BytesOf(const s: string): TBytes;
function NodeNumToId(num: LongWord): string;    { -> "!aabbccdd" }
function TryParseNodeId(const s: string; out num: LongWord): Boolean;

var
  { Hop limit applied to outgoing packets that don't specify one. 3 is the
    Meshtastic default; 7 is the maximum. Higher reaches further but adds mesh
    traffic, and some operators configure their routers to drop high-hop
    packets, which can stop your broadcasts being rebroadcast (and therefore
    stop the implicit ACK for public messages). }
  DefaultHopLimit: Integer = 3;

implementation

{ ======================= TPbWriter ======================= }

constructor TPbWriter.Create;
begin
  inherited Create;
  FStream := TMemoryStream.Create;
end;

destructor TPbWriter.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

procedure TPbWriter.WriteVarint(v: QWord);
var
  b: Byte;
begin
  repeat
    b := Byte(v and $7F);
    v := v shr 7;
    if v <> 0 then b := b or $80;
    FStream.WriteBuffer(b, 1);
  until v = 0;
end;

procedure TPbWriter.WriteTag(field, wire: Integer);
begin
  WriteVarint((QWord(field) shl 3) or QWord(wire));
end;

procedure TPbWriter.WriteVarintField(field: Integer; v: QWord);
begin
  WriteTag(field, 0);
  WriteVarint(v);
end;

procedure TPbWriter.WriteBoolField(field: Integer; v: Boolean);
begin
  WriteTag(field, 0);
  if v then WriteVarint(1) else WriteVarint(0);
end;

procedure TPbWriter.WriteFixed32Field(field: Integer; v: LongWord);
var
  buf: array[0..3] of Byte;
begin
  WriteTag(field, 5);
  buf[0] := Byte(v and $FF);
  buf[1] := Byte((v shr 8) and $FF);
  buf[2] := Byte((v shr 16) and $FF);
  buf[3] := Byte((v shr 24) and $FF);
  FStream.WriteBuffer(buf, 4);
end;

procedure TPbWriter.WriteBytesField(field: Integer; const b: TBytes);
begin
  WriteTag(field, 2);
  WriteVarint(QWord(Length(b)));
  if Length(b) > 0 then
    FStream.WriteBuffer(b[0], Length(b));
end;

procedure TPbWriter.WriteStringField(field: Integer; const s: string);
begin
  WriteBytesField(field, BytesOf(s));
end;

procedure TPbWriter.WriteMessageField(field: Integer; const msg: TBytes);
begin
  WriteBytesField(field, msg);   { same encoding as bytes/string }
end;

function TPbWriter.ToBytes: TBytes;
begin
  Result := nil;
  SetLength(Result, FStream.Size);
  if FStream.Size > 0 then
  begin
    FStream.Position := 0;
    FStream.ReadBuffer(Result[0], FStream.Size);
  end;
end;

{ ======================= TPbReader ======================= }

constructor TPbReader.Create(const AData: TBytes);
begin
  Create(AData, 0, Length(AData));
end;

constructor TPbReader.Create(const AData: TBytes; AStart, ALen: Integer);
begin
  inherited Create;
  FData := AData;
  FPos := AStart;
  FEnd := AStart + ALen;
end;

function TPbReader.Eof: Boolean;
begin
  Result := FPos >= FEnd;
end;

function TPbReader.ReadVarint: QWord;
var
  shift: Integer;
  b: Byte;
begin
  Result := 0;
  shift := 0;
  repeat
    if FPos >= FEnd then Break;
    b := FData[FPos];
    Inc(FPos);
    Result := Result or (QWord(b and $7F) shl shift);
    Inc(shift, 7);
  until (b and $80) = 0;
end;

function TPbReader.ReadTag(out field, wire: Integer): Boolean;
var
  t: QWord;
begin
  if Eof then Exit(False);
  t := ReadVarint;
  field := Integer(t shr 3);
  wire := Integer(t and $7);
  Result := True;
end;

procedure TPbReader.SkipField(wire: Integer);
var
  len: QWord;
begin
  case wire of
    0: ReadVarint;
    1: Inc(FPos, 8);
    5: Inc(FPos, 4);
    2: begin
         len := ReadVarint;
         Inc(FPos, Integer(len));
       end;
  else
    FPos := FEnd; { unknown wire type: stop }
  end;
  if FPos > FEnd then FPos := FEnd;
end;

function TPbReader.ReadFixed32: LongWord;
begin
  Result := 0;
  if FPos + 4 <= FEnd then
  begin
    Result := LongWord(FData[FPos]) or
              (LongWord(FData[FPos+1]) shl 8) or
              (LongWord(FData[FPos+2]) shl 16) or
              (LongWord(FData[FPos+3]) shl 24);
    Inc(FPos, 4);
  end
  else
    FPos := FEnd;
end;

function TPbReader.ReadFloat: Single;
var
  v: LongWord;
  s: Single;
begin
  v := ReadFixed32;
  Move(v, s, 4);
  Result := s;
end;

function TPbReader.ReadLenBytes: TBytes;
var
  len: Integer;
begin
  len := Integer(ReadVarint);
  if len < 0 then len := 0;
  if FPos + len > FEnd then len := FEnd - FPos;
  Result := nil;
  SetLength(Result, len);
  if len > 0 then
    Move(FData[FPos], Result[0], len);
  Inc(FPos, len);
end;

function TPbReader.ReadLenString: string;
var
  b: TBytes;
begin
  b := ReadLenBytes;
  SetLength(Result, Length(b));
  if Length(b) > 0 then
    Move(b[0], Result[1], Length(b));
end;

procedure TPbReader.ReadLenSlice(out AStart, ALen: Integer);
begin
  ALen := Integer(ReadVarint);
  if ALen < 0 then ALen := 0;
  if FPos + ALen > FEnd then ALen := FEnd - FPos;
  AStart := FPos;
  Inc(FPos, ALen);
end;

{ ======================= helpers ======================= }

function BytesOf(const s: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(s));
  if Length(s) > 0 then
    Move(s[1], Result[0], Length(s));
end;

function NodeNumToId(num: LongWord): string;
begin
  Result := '!' + LowerCase(IntToHex(num, 8));
end;

function TryParseNodeId(const s: string; out num: LongWord): Boolean;
var
  t: string;
  code: Integer;
  q: QWord;
begin
  Result := False;
  num := 0;
  t := Trim(s);
  if t = '' then Exit;
  if (t = '^all') or (SameText(t, 'all')) or (SameText(t, 'broadcast')) then
  begin
    num := BROADCAST_ADDR;
    Exit(True);
  end;
  if t[1] = '!' then
  begin
    Val('$' + Copy(t, 2, Length(t) - 1), q, code);
    if code = 0 then begin num := LongWord(q); Result := True; end;
    Exit;
  end;
  { plain decimal node number }
  Val(t, q, code);
  if code = 0 then begin num := LongWord(q); Result := True; end;
end;

{ ======================= encoders ======================= }

function EncodeWantConfig(nonce: LongWord): TBytes;
var
  w: TPbWriter;
begin
  w := TPbWriter.Create;
  try
    w.WriteVarintField(3, nonce);   { ToRadio.want_config_id = 3 }
    Result := w.ToBytes;
  finally
    w.Free;
  end;
end;

function EncodeDisconnect: TBytes;
var
  w: TPbWriter;
begin
  w := TPbWriter.Create;
  try
    w.WriteBoolField(4, True);      { ToRadio.disconnect = 4 }
    Result := w.ToBytes;
  finally
    w.Free;
  end;
end;

function EncodeHeartbeat: TBytes;
var
  w: TPbWriter;
begin
  w := TPbWriter.Create;
  try
    { ToRadio.heartbeat = 7, an empty Heartbeat message }
    w.WriteMessageField(7, nil);
    Result := w.ToBytes;
  finally
    w.Free;
  end;
end;

function BuildData(portnum: Integer; const payload: TBytes;
  wantResponse: Boolean): TBytes;
var
  w: TPbWriter;
begin
  w := TPbWriter.Create;
  try
    w.WriteVarintField(1, QWord(portnum));    { Data.portnum = 1 }
    if Length(payload) > 0 then
      w.WriteBytesField(2, payload);          { Data.payload = 2 }
    if wantResponse then
      w.WriteBoolField(3, True);              { Data.want_response = 3 }
    Result := w.ToBytes;
  finally
    w.Free;
  end;
end;

function BuildToRadioPacket(dest: LongWord; channelIndex, hopLimit: Integer;
  wantAck: Boolean; id: LongWord; const data: TBytes): TBytes;
var
  pkt, outer: TPbWriter;
begin
  pkt := TPbWriter.Create;
  try
    { MeshPacket: from(1) left unset so the device fills it in }
    pkt.WriteFixed32Field(2, dest);                 { to = 2 (fixed32) }
    if channelIndex > 0 then
      pkt.WriteVarintField(3, QWord(channelIndex));  { channel = 3 }
    pkt.WriteMessageField(4, data);                 { decoded = 4 (Data) }
    pkt.WriteFixed32Field(6, id);                   { id = 6 (fixed32) }
    { Always set a hop limit: a phone-originated DIRECT packet with hop_limit 0
      is never relayed, so /dm and /info to a multi-hop node would fail. When the
      caller doesn't specify one, use the configurable DefaultHopLimit. }
    if hopLimit <= 0 then hopLimit := DefaultHopLimit;
    pkt.WriteVarintField(9, QWord(hopLimit));        { hop_limit = 9 }
    if wantAck then
      pkt.WriteBoolField(10, True);                 { want_ack = 10 }

    outer := TPbWriter.Create;
    try
      outer.WriteMessageField(1, pkt.ToBytes);      { ToRadio.packet = 1 }
      Result := outer.ToBytes;
    finally
      outer.Free;
    end;
  finally
    pkt.Free;
  end;
end;

function EncodeTextPacket(dest: LongWord; channelIndex: Integer;
  wantAck: Boolean; id: LongWord; const text: string): TBytes;
begin
  Result := BuildToRadioPacket(dest, channelIndex, 0, wantAck, id,
    BuildData(PORT_TEXT_MESSAGE_APP, BytesOf(text), False));
end;

function EncodeTraceroutePacket(dest: LongWord; channelIndex, hopLimit: Integer;
  id: LongWord): TBytes;
begin
  { Payload is an empty RouteDiscovery; the mesh fills in the route.
    want_response = true so the destination sends the completed route back. }
  Result := BuildToRadioPacket(dest, channelIndex, hopLimit, False, id,
    BuildData(PORT_TRACEROUTE_APP, nil, True));
end;

function EncodeTelemetryPacket(dest: LongWord; channelIndex: Integer;
  id: LongWord): TBytes;
var
  w: TPbWriter;
  payload: TBytes;
begin
  { Payload is a Telemetry with an empty device_metrics (field 2), which asks
    the target to reply with its DeviceMetrics. want_response = true. }
  w := TPbWriter.Create;
  try
    w.WriteMessageField(2, nil);
    payload := w.ToBytes;
  finally
    w.Free;
  end;
  { hopLimit 0 -> DefaultHopLimit, so /info follows the configured setting. }
  Result := BuildToRadioPacket(dest, channelIndex, 0, False, id,
    BuildData(PORT_TELEMETRY_APP, payload, True));
end;

function EncodeNodeInfoPacket(dest: LongWord; channelIndex: Integer;
  id: LongWord; const myId: string): TBytes;
var
  w: TPbWriter;
  payload: TBytes;
begin
  { Payload is our own User (just the id is enough), and want_response=true asks
    the target to send its NodeInfo back so we learn its name. }
  w := TPbWriter.Create;
  try
    if myId <> '' then w.WriteStringField(1, myId);   { User.id = 1 }
    payload := w.ToBytes;
  finally
    w.Free;
  end;
  Result := BuildToRadioPacket(dest, channelIndex, 0, False, id,
    BuildData(PORT_NODEINFO_APP, payload, True));
end;

{ ======================= decoders ======================= }

function DecodeUser(const data: TBytes; s, l: Integer): TMeshUser;
var
  r: TPbReader;
  f, w: Integer;
begin
  Result := Default(TMeshUser);
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        1: Result.Id := r.ReadLenString;
        2: Result.LongName := r.ReadLenString;
        3: Result.ShortName := r.ReadLenString;
        5: Result.HwModel := Integer(r.ReadVarint);
        8: begin r.ReadLenBytes; Result.HasKey := True; end;
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

procedure DecodePosition(const data: TBytes; s, l: Integer; var n: TMeshNode);
var
  r: TPbReader;
  f, w: Integer;
begin
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        1: begin n.LatI := LongInt(r.ReadFixed32); n.HasPos := True; end;
        2: begin n.LonI := LongInt(r.ReadFixed32); n.HasPos := True; end;
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

procedure DecodeDeviceMetrics(const data: TBytes; s, l: Integer; var n: TMeshNode);
var
  r: TPbReader;
  f, w: Integer;
begin
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        1: begin n.Battery := Integer(r.ReadVarint); n.HasBattery := True; end;
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

function DecodeNodeInfo(const data: TBytes; s, l: Integer): TMeshNode;
var
  r: TPbReader;
  f, w, ss, ll: Integer;
begin
  Result := Default(TMeshNode);
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        1: Result.Num := LongWord(r.ReadVarint);
        2: begin r.ReadLenSlice(ss, ll); Result.User := DecodeUser(data, ss, ll); Result.HasUser := True; end;
        3: begin r.ReadLenSlice(ss, ll); DecodePosition(data, ss, ll, Result); end;
        4: Result.Snr := r.ReadFloat;
        5: Result.LastHeard := r.ReadFixed32;
        6: begin r.ReadLenSlice(ss, ll); DecodeDeviceMetrics(data, ss, ll, Result); end;
        9: begin Result.HopsAway := Integer(r.ReadVarint); Result.HasHops := True; end;
        10: Result.IsFavorite := r.ReadVarint <> 0;
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

function DecodeChannelSettings(const data: TBytes; s, l: Integer): string;
var
  r: TPbReader;
  f, w: Integer;
begin
  Result := '';
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        3: Result := r.ReadLenString;   { ChannelSettings.name = 3 }
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

function DecodeChannel(const data: TBytes; s, l: Integer): TChannelInfo;
var
  r: TPbReader;
  f, w, ss, ll: Integer;
begin
  Result := Default(TChannelInfo);
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        1: Result.Index := Integer(r.ReadVarint);   { Channel.index = 1 }
        2: begin r.ReadLenSlice(ss, ll); Result.Name := DecodeChannelSettings(data, ss, ll); end;
        3: Result.Role := Integer(r.ReadVarint);    { Channel.role = 3 }
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

function DecodeData(const data: TBytes; s, l: Integer): TDataMsg;
var
  r: TPbReader;
  f, w: Integer;
begin
  Result := Default(TDataMsg);
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        1: Result.Portnum := Integer(r.ReadVarint);
        2: Result.Payload := r.ReadLenBytes;
        3: Result.WantResponse := r.ReadVarint <> 0;
        4: Result.Dest := r.ReadFixed32;
        5: Result.Source := r.ReadFixed32;
        6: Result.RequestId := r.ReadFixed32;
        7: Result.ReplyId := r.ReadFixed32;
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

function DecodeMeshPacket(const data: TBytes; s, l: Integer): TMeshPacket;
var
  r: TPbReader;
  f, w, ss, ll: Integer;
begin
  Result := Default(TMeshPacket);
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        1: Result.FromNum := r.ReadFixed32;
        2: Result.ToNum := r.ReadFixed32;
        3: Result.Channel := Integer(r.ReadVarint);
        4: begin r.ReadLenSlice(ss, ll); Result.Decoded := DecodeData(data, ss, ll); Result.HasDecoded := True; end;
        5: begin r.ReadLenBytes; Result.Encrypted := True; end;
        6: Result.Id := r.ReadFixed32;
        7: Result.RxTime := r.ReadFixed32;
        8: Result.RxSnr := r.ReadFloat;
        9: Result.HopLimit := Integer(r.ReadVarint);
        10: Result.WantAck := r.ReadVarint <> 0;
        12: Result.RxRssi := LongInt(LongWord(r.ReadVarint));
        15: Result.HopStart := Integer(r.ReadVarint);
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

function DecodeFromRadio(const b: TBytes): TFromRadio;
var
  r: TPbReader;
  f, w, ss, ll: Integer;
  mi: TPbReader;
  mf, mw: Integer;
begin
  Result := Default(TFromRadio);
  Result.Kind := frUnknown;
  r := TPbReader.Create(b);
  try
    while r.ReadTag(f, w) do
      case f of
        1: Result.Id := LongWord(r.ReadVarint);            { FromRadio.id = 1 }
        2: begin r.ReadLenSlice(ss, ll); Result.Packet := DecodeMeshPacket(b, ss, ll); Result.Kind := frPacket; end;
        3: begin
             r.ReadLenSlice(ss, ll);                       { MyNodeInfo }
             mi := TPbReader.Create(b, ss, ll);
             try
               while mi.ReadTag(mf, mw) do
                 if mf = 1 then Result.MyNodeNum := LongWord(mi.ReadVarint)
                 else mi.SkipField(mw);
             finally
               mi.Free;
             end;
             Result.Kind := frMyInfo;
           end;
        4: begin r.ReadLenSlice(ss, ll); Result.Node := DecodeNodeInfo(b, ss, ll); Result.Kind := frNodeInfo; end;
        6: begin
             r.ReadLenSlice(ss, ll);                       { LogRecord }
             mi := TPbReader.Create(b, ss, ll);
             try
               while mi.ReadTag(mf, mw) do
                 if mf = 1 then Result.LogText := mi.ReadLenString
                 else mi.SkipField(mw);
             finally
               mi.Free;
             end;
             Result.Kind := frLogRecord;
           end;
        7: begin Result.ConfigCompleteId := LongWord(r.ReadVarint); Result.Kind := frConfigComplete; end;
        8: begin r.ReadVarint; Result.Kind := frRebooted; end;
        10: begin r.ReadLenSlice(ss, ll); Result.Channel := DecodeChannel(b, ss, ll); Result.Kind := frChannel; end;
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

function DecodeRouteDiscovery(const b: TBytes): TRouteDiscovery;
var
  r, sub: TPbReader;
  f, w, ss, ll: Integer;
begin
  Result := Default(TRouteDiscovery);
  r := TPbReader.Create(b);
  try
    while r.ReadTag(f, w) do
    begin
      if ((f = 1) or (f = 3)) and (w = 2) then
      begin
        { packed repeated fixed32 (route / route_back) }
        r.ReadLenSlice(ss, ll);
        sub := TPbReader.Create(b, ss, ll);
        try
          while not sub.Eof do
          begin
            if f = 1 then
            begin
              SetLength(Result.Route, Length(Result.Route) + 1);
              Result.Route[High(Result.Route)] := sub.ReadFixed32;
            end
            else
            begin
              SetLength(Result.RouteBack, Length(Result.RouteBack) + 1);
              Result.RouteBack[High(Result.RouteBack)] := sub.ReadFixed32;
            end;
          end;
        finally
          sub.Free;
        end;
      end
      else if ((f = 2) or (f = 4)) and (w = 2) then
      begin
        { packed repeated int32 (snr_towards / snr_back) }
        r.ReadLenSlice(ss, ll);
        sub := TPbReader.Create(b, ss, ll);
        try
          while not sub.Eof do
          begin
            if f = 2 then
            begin
              SetLength(Result.SnrTowards, Length(Result.SnrTowards) + 1);
              Result.SnrTowards[High(Result.SnrTowards)] := LongInt(LongWord(sub.ReadVarint));
            end
            else
            begin
              SetLength(Result.SnrBack, Length(Result.SnrBack) + 1);
              Result.SnrBack[High(Result.SnrBack)] := LongInt(LongWord(sub.ReadVarint));
            end;
          end;
        finally
          sub.Free;
        end;
      end
      else
        r.SkipField(w);
    end;
  finally
    r.Free;
  end;
end;

function DecodeDeviceMetrics(const data: TBytes; s, l: Integer): TDeviceMetrics;
var
  r: TPbReader;
  f, w: Integer;
begin
  Result := Default(TDeviceMetrics);
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        1: begin Result.Battery := LongWord(r.ReadVarint); Result.HasBattery := True; end;
        2: begin Result.Voltage := r.ReadFloat; Result.HasVoltage := True; end;
        3: begin Result.ChanUtil := r.ReadFloat; Result.HasChanUtil := True; end;
        4: begin Result.AirTx := r.ReadFloat; Result.HasAirTx := True; end;
        5: begin Result.Uptime := LongWord(r.ReadVarint); Result.HasUptime := True; end;
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

function DecodeEnvMetrics(const data: TBytes; s, l: Integer): TEnvMetrics;
var
  r: TPbReader;
  f, w: Integer;
begin
  Result := Default(TEnvMetrics);
  r := TPbReader.Create(data, s, l);
  try
    while r.ReadTag(f, w) do
      case f of
        1: begin Result.Temp := r.ReadFloat; Result.HasTemp := True; end;
        2: begin Result.Humidity := r.ReadFloat; Result.HasHumidity := True; end;
        3: begin Result.Pressure := r.ReadFloat; Result.HasPressure := True; end;
        4: begin Result.Gas := r.ReadFloat; Result.HasGas := True; end;
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

function DecodeTelemetry(const b: TBytes): TTelemetry;
var
  r: TPbReader;
  f, w, ss, ll: Integer;
begin
  Result := Default(TTelemetry);
  r := TPbReader.Create(b);
  try
    while r.ReadTag(f, w) do
      case f of
        2: begin r.ReadLenSlice(ss, ll); Result.Device := DecodeDeviceMetrics(b, ss, ll); Result.HasDevice := True; end;
        3: begin r.ReadLenSlice(ss, ll); Result.Env := DecodeEnvMetrics(b, ss, ll); Result.HasEnv := True; end;
      else
        r.SkipField(w);
      end;
  finally
    r.Free;
  end;
end;

end.
