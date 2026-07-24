unit MeshBLE;
{
  ============================ IMPORTANT ============================
  Linux-only BLE transport for Meshtastic, using BlueZ over D-Bus.

  This unit is OPT-IN. It is only compiled when you build with -dMESH_BLE,
  so it can never affect the default (serial) build. It requires:
      * Linux with BlueZ 5.43+  (the same requirement the official tools have)
      * libdbus + FPC's 'dbus' unit
      * the radio already PAIRED/BONDED with your machine
        (use bluetoothctl once: scan on / pair XX:.. / trust XX:..)

  HONEST STATUS: unlike the serial transport, this BLE code could not be
  exercised against a real radio in the environment where it was written.
  Treat it as a working design that needs verification on your hardware.
  If GATT auto-discovery misbehaves, you can bypass it by passing explicit
  characteristic object paths (see the second constructor).

  Meshtastic BLE (per the official Client API docs):
      Service   6ba1b218-15a8-461f-9fa8-5dcae273eafd
      ToRadio   f75c76d2-129e-4dad-a1dd-7866124401e7   (write)
      FromRadio 2c55e69e-4993-11ed-b878-0242ac120002   (read; drain until empty)
      FromNum   ed9da18c-a800-4f66-a670-aa7547e34453   (notify; optimization only)

  There is NO 4-byte framing on BLE: each write is one whole ToRadio protobuf,
  and each read of FromRadio returns one whole FromRadio protobuf (or an empty
  buffer when the device's queue is drained). This transport therefore polls
  FromRadio on a timer instead of subscribing to FromNum notifications, which
  keeps the D-Bus code to plain method calls.
  ==================================================================
}
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, dbus, MeshTransport;

const
  UUID_TORADIO   = 'f75c76d2-129e-4dad-a1dd-7866124401e7';
  UUID_FROMRADIO = '2c55e69e-4993-11ed-b878-0242ac120002';
  UUID_FROMNUM   = 'ed9da18c-a800-4f66-a670-aa7547e34453';

type
  TBLETransport = class(TInterfacedObject, ITransport)
  private
    type
      TBLEReader = class(TThread)
      private
        FOwner: TBLETransport;
      protected
        procedure Execute; override;
      public
        constructor Create(AOwner: TBLETransport);
      end;
  private
    FConn: PDBusConnection;
    FDevPath: string;
    FToPath: string;
    FFromPath: string;
    FLock: TCriticalSection;
    FQueue: TStringList;   { received FromRadio protobufs, as RawByteString }
    FReader: TBLEReader;
    FStop: Boolean;
    FOpen: Boolean;
    procedure PushPacket(const b: TBytes);
    function ReadFromRadio(out b: TBytes): Boolean;
    procedure ConnectDevice;
    function Discover: Boolean;
  public
    { Auto-discovery from a BLE address like AA:BB:CC:DD:EE:FF. AAdapter is the
      BlueZ controller name, normally hci0. }
    constructor Create(const AAddress: string; const AAdapter: string = 'hci0');
    { Explicit paths, if you prefer to skip discovery. Object paths look like
      /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/serviceXXXX/charYYYY }
    constructor CreatePaths(const AToPath, AFromPath: string);
    destructor Destroy; override;
    { ITransport }
    procedure Send(const b: TBytes);
    function TryGetPacket(out b: TBytes): Boolean;
    function TryGetDebug(out s: string): Boolean;
    function IsOpen: Boolean;
    procedure Close;
  end;

implementation

{ ---- small D-Bus helpers ------------------------------------------------- }

function CheckErr(const where: string; var err: DBusError): Boolean;
begin
  if dbus_error_is_set(@err) <> 0 then
  begin
    { Surface the reason but let the caller decide what to do. }
    WriteLn(ErrOutput, 'BLE D-Bus error in ', where, ': ', err.message);
    dbus_error_free(@err);
    Result := False;
  end
  else
    Result := True;
end;

{ Call a no-argument BlueZ method (e.g. Device1.Connect). Returns True on ok. }
function CallVoid(conn: PDBusConnection; const path, iface, method: string): Boolean;
var
  msg, reply: PDBusMessage;
  err: DBusError;
begin
  Result := False;
  msg := dbus_message_new_method_call('org.bluez', PChar(path), PChar(iface), PChar(method));
  if msg = nil then Exit;
  dbus_error_init(@err);
  reply := dbus_connection_send_with_reply_and_block(conn, msg, 20000, @err);
  dbus_message_unref(msg);
  if not CheckErr(method, err) then Exit;
  if reply <> nil then
  begin
    dbus_message_unref(reply);
    Result := True;
  end;
end;

{ Append an empty a{sv} options dictionary to a message iterator. }
procedure AppendEmptyOptions(var it: DBusMessageIter);
var
  sub: DBusMessageIter;
begin
  dbus_message_iter_open_container(@it, DBUS_TYPE_ARRAY, '{sv}', @sub);
  dbus_message_iter_close_container(@it, @sub);
end;

{ GattCharacteristic1.WriteValue(ay value, a{sv} options) }
function GattWrite(conn: PDBusConnection; const charPath: string; const b: TBytes): Boolean;
var
  msg, reply: PDBusMessage;
  it, arr: DBusMessageIter;
  err: DBusError;
  i: Integer;
  bv: Byte;
begin
  Result := False;
  msg := dbus_message_new_method_call('org.bluez', PChar(charPath),
    'org.bluez.GattCharacteristic1', 'WriteValue');
  if msg = nil then Exit;
  dbus_message_iter_init_append(msg, @it);
  { value: array of bytes }
  dbus_message_iter_open_container(@it, DBUS_TYPE_ARRAY, 'y', @arr);
  for i := 0 to High(b) do
  begin
    bv := b[i];
    dbus_message_iter_append_basic(@arr, DBUS_TYPE_BYTE, @bv);
  end;
  dbus_message_iter_close_container(@it, @arr);
  { options: empty a{sv} }
  AppendEmptyOptions(it);

  dbus_error_init(@err);
  reply := dbus_connection_send_with_reply_and_block(conn, msg, 20000, @err);
  dbus_message_unref(msg);
  if not CheckErr('WriteValue', err) then Exit;
  if reply <> nil then
  begin
    dbus_message_unref(reply);
    Result := True;
  end;
end;

{ GattCharacteristic1.ReadValue(a{sv} options) -> ay }
function GattRead(conn: PDBusConnection; const charPath: string; out b: TBytes): Boolean;
var
  msg, reply: PDBusMessage;
  it, arr: DBusMessageIter;
  err: DBusError;
  bv: Byte;
begin
  Result := False;
  b := nil;
  msg := dbus_message_new_method_call('org.bluez', PChar(charPath),
    'org.bluez.GattCharacteristic1', 'ReadValue');
  if msg = nil then Exit;
  dbus_message_iter_init_append(msg, @it);
  AppendEmptyOptions(it);

  dbus_error_init(@err);
  reply := dbus_connection_send_with_reply_and_block(conn, msg, 20000, @err);
  dbus_message_unref(msg);
  if not CheckErr('ReadValue', err) then Exit;
  if reply = nil then Exit;

  if dbus_message_iter_init(reply, @it) <> 0 then
    if dbus_message_iter_get_arg_type(@it) = DBUS_TYPE_ARRAY then
    begin
      dbus_message_iter_recurse(@it, @arr);
      while dbus_message_iter_get_arg_type(@arr) = DBUS_TYPE_BYTE do
      begin
        dbus_message_iter_get_basic(@arr, @bv);
        SetLength(b, Length(b) + 1);
        b[High(b)] := bv;
        dbus_message_iter_next(@arr);
      end;
    end;
  dbus_message_unref(reply);
  Result := True;
end;

{ Walk ObjectManager.GetManagedObjects to map characteristic UUID -> path,
  restricted to object paths under the given device path. }
function DiscoverChars(conn: PDBusConnection; const devPath: string;
  out toPath, fromPath: string): Boolean;
var
  msg, reply: PDBusMessage;
  err: DBusError;
  objs, entry, ifaces, ifentry, props, pentry, variant: DBusMessageIter;
  objPath, ifName, propName, uuid: PChar;
  curPath, curUuid: string;
  isChar: Boolean;

  function StrArg(var iter: DBusMessageIter): string;
  var p: PChar;
  begin
    p := nil;
    dbus_message_iter_get_basic(@iter, @p);
    if p <> nil then Result := string(p) else Result := '';
  end;

begin
  Result := False;
  toPath := '';
  fromPath := '';
  msg := dbus_message_new_method_call('org.bluez', '/',
    'org.freedesktop.DBus.ObjectManager', 'GetManagedObjects');
  if msg = nil then Exit;
  dbus_error_init(@err);
  reply := dbus_connection_send_with_reply_and_block(conn, msg, 20000, @err);
  dbus_message_unref(msg);
  if not CheckErr('GetManagedObjects', err) then Exit;
  if reply = nil then Exit;

  { reply is a{o a{s a{s v}}} }
  if dbus_message_iter_init(reply, @objs) <> 0 then
    if dbus_message_iter_get_arg_type(@objs) = DBUS_TYPE_ARRAY then
    begin
      dbus_message_iter_recurse(@objs, @entry);
      while dbus_message_iter_get_arg_type(@entry) = DBUS_TYPE_DICT_ENTRY do
      begin
        dbus_message_iter_recurse(@entry, @ifaces);       { key: object path }
        objPath := nil;
        dbus_message_iter_get_basic(@ifaces, @objPath);
        if objPath <> nil then curPath := string(objPath) else curPath := '';
        dbus_message_iter_next(@ifaces);                  { value: a{s a{sv}} }

        if (curPath <> '') and (Pos(devPath, curPath) = 1) and
           (dbus_message_iter_get_arg_type(@ifaces) = DBUS_TYPE_ARRAY) then
        begin
          dbus_message_iter_recurse(@ifaces, @ifentry);
          while dbus_message_iter_get_arg_type(@ifentry) = DBUS_TYPE_DICT_ENTRY do
          begin
            dbus_message_iter_recurse(@ifentry, @props);  { key: iface name }
            ifName := nil;
            dbus_message_iter_get_basic(@props, @ifName);
            isChar := (ifName <> nil) and
                      (string(ifName) = 'org.bluez.GattCharacteristic1');
            dbus_message_iter_next(@props);               { value: a{sv} props }

            if isChar and (dbus_message_iter_get_arg_type(@props) = DBUS_TYPE_ARRAY) then
            begin
              curUuid := '';
              dbus_message_iter_recurse(@props, @pentry);
              while dbus_message_iter_get_arg_type(@pentry) = DBUS_TYPE_DICT_ENTRY do
              begin
                dbus_message_iter_recurse(@pentry, @variant);  { key: prop name }
                propName := nil;
                dbus_message_iter_get_basic(@variant, @propName);
                dbus_message_iter_next(@variant);              { value: variant }
                if (propName <> nil) and (string(propName) = 'UUID') and
                   (dbus_message_iter_get_arg_type(@variant) = DBUS_TYPE_VARIANT) then
                begin
                  dbus_message_iter_recurse(@variant, @variant);
                  uuid := nil;
                  dbus_message_iter_get_basic(@variant, @uuid);
                  if uuid <> nil then curUuid := LowerCase(string(uuid));
                end;
                dbus_message_iter_next(@pentry);
              end;

              if curUuid = UUID_TORADIO then toPath := curPath
              else if curUuid = UUID_FROMRADIO then fromPath := curPath;
            end;

            dbus_message_iter_next(@ifentry);
          end;
        end;

        dbus_message_iter_next(@entry);
      end;
    end;

  dbus_message_unref(reply);
  Result := (toPath <> '') and (fromPath <> '');
end;

{ ---- TBLETransport.TBLEReader ------------------------------------------- }

constructor TBLETransport.TBLEReader.Create(AOwner: TBLETransport);
begin
  FOwner := AOwner;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TBLETransport.TBLEReader.Execute;
var
  b: TBytes;
  gotAny: Boolean;
  drained: Integer;
begin
  while not Terminated and not FOwner.FStop do
  begin
    gotAny := False;
    drained := 0;
    { Drain the FromRadio queue until it returns empty (per BLE docs). }
    while (drained < 32) and FOwner.ReadFromRadio(b) do
    begin
      if Length(b) = 0 then Break;
      FOwner.PushPacket(b);
      gotAny := True;
      Inc(drained);
    end;
    if not gotAny then
      Sleep(120)     { idle poll interval }
    else
      Sleep(10);
  end;
end;

{ ---- TBLETransport ------------------------------------------------------- }

function AddrToDevPath(const addr, adapter: string): string;
begin
  { BlueZ object path, e.g. /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF. The adapter
    is usually hci0, but a machine with more than one Bluetooth controller may
    need hci1 etc. }
  Result := '/org/bluez/' + adapter + '/dev_' +
            UpperCase(StringReplace(addr, ':', '_', [rfReplaceAll]));
end;

constructor TBLETransport.Create(const AAddress: string; const AAdapter: string);
var
  err: DBusError;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FQueue := TStringList.Create;
  FStop := False;
  FOpen := False;

  dbus_error_init(@err);
  FConn := dbus_bus_get(DBUS_BUS_SYSTEM, @err);
  if (FConn = nil) or (dbus_error_is_set(@err) <> 0) then
  begin
    CheckErr('bus_get', err);
    raise Exception.Create('Cannot connect to the system D-Bus (is BlueZ running?)');
  end;

  FDevPath := AddrToDevPath(AAddress, AAdapter);
  ConnectDevice;
  if not Discover then
    raise Exception.Create('Could not find Meshtastic GATT characteristics. ' +
      'Make sure the device is paired/trusted and connected, or use CreatePaths.');
  FOpen := True;
  FReader := TBLEReader.Create(Self);
end;

constructor TBLETransport.CreatePaths(const AToPath, AFromPath: string);
var
  err: DBusError;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FQueue := TStringList.Create;
  FStop := False;

  dbus_error_init(@err);
  FConn := dbus_bus_get(DBUS_BUS_SYSTEM, @err);
  if FConn = nil then
    raise Exception.Create('Cannot connect to the system D-Bus.');
  FToPath := AToPath;
  FFromPath := AFromPath;
  FOpen := True;
  FReader := TBLEReader.Create(Self);
end;

destructor TBLETransport.Destroy;
begin
  Close;
  FQueue.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TBLETransport.ConnectDevice;
begin
  { Best-effort: if already connected this is a no-op on the BlueZ side. }
  CallVoid(FConn, FDevPath, 'org.bluez.Device1', 'Connect');
end;

function TBLETransport.Discover: Boolean;
begin
  Result := DiscoverChars(FConn, FDevPath, FToPath, FFromPath);
end;

procedure TBLETransport.PushPacket(const b: TBytes);
var
  rb: RawByteString;
begin
  SetLength(rb, Length(b));
  if Length(b) > 0 then Move(b[0], rb[1], Length(b));
  FLock.Enter;
  try
    FQueue.Add(rb);
  finally
    FLock.Leave;
  end;
end;

function TBLETransport.ReadFromRadio(out b: TBytes): Boolean;
begin
  Result := GattRead(FConn, FFromPath, b);
end;

procedure TBLETransport.Send(const b: TBytes);
begin
  if FOpen then
    GattWrite(FConn, FToPath, b);
end;

function TBLETransport.TryGetPacket(out b: TBytes): Boolean;
var
  rb: RawByteString;
begin
  b := nil;
  Result := False;
  FLock.Enter;
  try
    if FQueue.Count > 0 then
    begin
      rb := FQueue[0];
      FQueue.Delete(0);
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
  if Result then
  begin
    SetLength(b, Length(rb));
    if Length(rb) > 0 then Move(rb[1], b[0], Length(rb));
  end;
end;

function TBLETransport.TryGetDebug(out s: string): Boolean;
begin
  s := '';
  Result := False;   { BLE carries no debug console text }
end;

function TBLETransport.IsOpen: Boolean;
begin
  Result := FOpen;
end;

procedure TBLETransport.Close;
begin
  if not FOpen then Exit;
  FOpen := False;
  FStop := True;
  if FReader <> nil then
  begin
    FReader.WaitFor;
    FReader.Free;
    FReader := nil;
  end;
  { We intentionally do not force a BlueZ Disconnect here: other apps may be
    using the device. dbus_bus_get returns a shared connection; do not unref. }
end;

end.
