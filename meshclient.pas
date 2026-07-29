unit MeshClient;
{
  High-level Meshtastic client. Owns a transport, maintains the node database
  and channel list, performs the want_config handshake, sends text / direct
  messages / traceroute, and dispatches incoming packets to callbacks.

  Call BeginConfig once after connecting, then call Poll() frequently from the
  main loop (it is non-blocking and drains whatever the transport has ready).
}
{$mode objfpc}{$H+}

interface

uses
  SysUtils, MeshProto, MeshTransport;

type
  TTextEvent  = procedure(fromNum, toNum: LongWord; channel: Integer;
                          const text: string; direct: Boolean;
                          hopLimit, hopStart: Integer) of object;
  TLineEvent  = procedure(const line: string) of object;
  TNodeEvent  = procedure(const node: TMeshNode) of object;
  TAckEvent   = procedure(reqId: LongWord; success: Boolean; code: Integer) of object;
  TTelemetryEvent = procedure(fromNum: LongWord; const t: TTelemetry) of object;
  TNodeInfoEvent  = procedure(fromNum: LongWord; const shortName, longName: string) of object;

  { Running RF-quality statistics over the packets the radio has decoded and
    forwarded this session (their rx_snr/rx_rssi fields). }
  TRfStats = record
    Count: Integer;
    SnrLast, SnrMin, SnrMax, SnrSum: Single;
    RssiLast, RssiMin, RssiMax: LongInt;
    RssiSum: Int64;
  end;

  TMeshClient = class
  private
    FT: ITransport;
    FRf: TRfStats;
    FNodes: array of TMeshNode;
    FChannels: array of TChannelInfo;
    FPendingAcks: array of LongWord;
    FMyNum: LongWord;
    FNonce: LongWord;
    FConfigDone: Boolean;
    FShowIds: Boolean;   { NodeLabel appends "(!id)" after the short name }
    FLastBeat: TDateTime;   { last time a keep-alive heartbeat was sent }
    FOnText: TTextEvent;
    FOnTrace: TLineEvent;
    FOnDebug: TLineEvent;
    FOnNode: TNodeEvent;
    FOnConfig: TLineEvent;
    FOnAck: TAckEvent;
    FOnTelemetry: TTelemetryEvent;
    FOnNodeInfo: TNodeInfoEvent;
    function NodeIndex(num: LongWord): Integer;
    procedure SetNodeUser(num: LongWord; const u: TMeshUser);
    procedure UpsertNode(const n: TMeshNode);
    procedure TouchNode(num: LongWord; snr: Single; rxTime: LongWord);
    procedure SetChannel(const c: TChannelInfo);
    procedure AddPending(id: LongWord);
    function TakePending(id: LongWord): Boolean;
    procedure HandlePacket(const p: TMeshPacket);
    procedure HandleFromRadio(const b: TBytes);
    procedure MaybeHeartbeat;
  public
    constructor Create(AT: ITransport);
    procedure BeginConfig;
    procedure Poll;
    procedure Disconnect;

    function NodeCount: Integer;
    function GetNode(i: Integer): TMeshNode;
    function ChannelCount: Integer;
    function GetChannel(i: Integer): TChannelInfo;
    function MyNum: LongWord;
    function ConfigComplete: Boolean;
    function RfStats: TRfStats;

    function ResolveTarget(const s: string; out num: LongWord): Boolean;
    function NodeLabel(num: LongWord): string;

    function SendText(dest: LongWord; channel: Integer; const text: string;
      wantAck: Boolean): LongWord;
    function SendTraceroute(dest: LongWord; channel, hopLimit: Integer): LongWord;
    function SendTelemetryRequest(dest: LongWord; channel: Integer): LongWord;
    function SendNodeInfoRequest(dest: LongWord; channel: Integer): LongWord;

    property OnText: TTextEvent read FOnText write FOnText;
    property OnTrace: TLineEvent read FOnTrace write FOnTrace;
    property OnDebug: TLineEvent read FOnDebug write FOnDebug;
    property OnNode: TNodeEvent read FOnNode write FOnNode;
    property OnConfig: TLineEvent read FOnConfig write FOnConfig;
    property OnAck: TAckEvent read FOnAck write FOnAck;
    property OnTelemetry: TTelemetryEvent read FOnTelemetry write FOnTelemetry;
    property OnNodeInfo: TNodeInfoEvent read FOnNodeInfo write FOnNodeInfo;
    { False (default): NodeLabel gives just the short name, e.g. "OO11".
      True: it gives "OO11 (!458f4727)". Nodes with no known name always
      show their !id either way. }
    property ShowIds: Boolean read FShowIds write FShowIds;
  end;

implementation

const
  { The radio stops streaming to a serial/BLE client that goes quiet, so we must
    periodically send a ToRadio.heartbeat to keep the connection awake. The
    official client uses 300s; 120s gives a safe margin. }
  HEARTBEAT_SECS = 120;

function RandId: LongWord;
begin
  repeat
    Result := (LongWord(Random($10000)) shl 16) or LongWord(Random($10000));
  until Result <> 0;
end;

{ Decode Routing.error_reason (field 3, varint). Returns True if present. }
function DecodeRoutingError(const payload: TBytes; out code: Integer): Boolean;
var
  r: TPbReader;
  f, w: Integer;
begin
  Result := False;
  code := 0;
  r := TPbReader.Create(payload);
  try
    while r.ReadTag(f, w) do
      if (f = 3) and (w = 0) then
      begin
        code := Integer(r.ReadVarint);
        Result := True;
      end
      else
        r.SkipField(w);
  finally
    r.Free;
  end;
end;

constructor TMeshClient.Create(AT: ITransport);
begin
  inherited Create;
  FT := AT;
  FMyNum := 0;
  FNonce := 0;
  FConfigDone := False;
  FShowIds := False;
  FLastBeat := Now;
  Randomize;
end;

procedure TMeshClient.BeginConfig;
begin
  FConfigDone := False;
  FNonce := RandId;
  FLastBeat := Now;
  FT.Send(EncodeWantConfig(FNonce));
end;

procedure TMeshClient.Disconnect;
begin
  if (FT <> nil) and FT.IsOpen then
  begin
    try FT.Send(EncodeDisconnect); except end;
    FT.Close;
  end;
end;

{ ---- node DB ---- }

function TMeshClient.NodeIndex(num: LongWord): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FNodes) do
    if FNodes[i].Num = num then Exit(i);
  Result := -1;
end;

procedure TMeshClient.SetNodeUser(num: LongWord; const u: TMeshUser);
var
  idx: Integer;
  n: TMeshNode;
begin
  idx := NodeIndex(num);
  if idx < 0 then
  begin
    n := Default(TMeshNode);
    n.Num := num;
    SetLength(FNodes, Length(FNodes) + 1);
    idx := High(FNodes);
    FNodes[idx] := n;
  end;
  FNodes[idx].User := u;
  FNodes[idx].HasUser := True;
end;

procedure TMeshClient.UpsertNode(const n: TMeshNode);
var
  idx: Integer;
begin
  idx := NodeIndex(n.Num);
  if idx < 0 then
  begin
    SetLength(FNodes, Length(FNodes) + 1);
    FNodes[High(FNodes)] := n;
  end
  else
  begin
    { merge: keep existing user name if the update has none }
    if not n.HasUser and FNodes[idx].HasUser then
    begin
      FNodes[idx].Snr := n.Snr;
      FNodes[idx].LastHeard := n.LastHeard;
      if n.HasPos then begin FNodes[idx].HasPos := True; FNodes[idx].LatI := n.LatI; FNodes[idx].LonI := n.LonI; end;
      if n.HasBattery then begin FNodes[idx].HasBattery := True; FNodes[idx].Battery := n.Battery; end;
      if n.HasHops then begin FNodes[idx].HasHops := True; FNodes[idx].HopsAway := n.HopsAway; end;
    end
    else
      FNodes[idx] := n;
  end;
end;

procedure TMeshClient.TouchNode(num: LongWord; snr: Single; rxTime: LongWord);
var
  idx: Integer;
  n: TMeshNode;
begin
  if (num = 0) or (num = BROADCAST_ADDR) then Exit;
  idx := NodeIndex(num);
  if idx < 0 then
  begin
    FillChar(n, SizeOf(n), 0);
    n.Num := num;
    n.Snr := snr;
    n.LastHeard := rxTime;
    UpsertNode(n);
  end
  else
  begin
    if snr <> 0 then FNodes[idx].Snr := snr;
    if rxTime <> 0 then FNodes[idx].LastHeard := rxTime;
  end;
end;

{ ---- channels ---- }

procedure TMeshClient.SetChannel(const c: TChannelInfo);
var
  i: Integer;
begin
  for i := 0 to High(FChannels) do
    if FChannels[i].Index = c.Index then
    begin
      FChannels[i] := c;
      Exit;
    end;
  SetLength(FChannels, Length(FChannels) + 1);
  FChannels[High(FChannels)] := c;
end;

{ ---- pending acks ---- }

procedure TMeshClient.AddPending(id: LongWord);
begin
  SetLength(FPendingAcks, Length(FPendingAcks) + 1);
  FPendingAcks[High(FPendingAcks)] := id;
end;

function TMeshClient.TakePending(id: LongWord): Boolean;
var
  i, j: Integer;
begin
  Result := False;
  for i := 0 to High(FPendingAcks) do
    if FPendingAcks[i] = id then
    begin
      for j := i to High(FPendingAcks) - 1 do
        FPendingAcks[j] := FPendingAcks[j + 1];
      SetLength(FPendingAcks, Length(FPendingAcks) - 1);
      Exit(True);
    end;
end;

{ ---- dispatch ---- }

procedure TMeshClient.HandlePacket(const p: TMeshPacket);
var
  rd: TRouteDiscovery;
  code: Integer;
  txt, line: string;
  i: Integer;
  direct: Boolean;
  u: TMeshUser;
begin
  TouchNode(p.FromNum, p.RxSnr, p.RxTime);

  { RF stats: only packets that actually crossed the air carry rx values;
    packets originated locally or via the API leave them zero. }
  if (p.RxSnr <> 0) or (p.RxRssi <> 0) then
  begin
    if FRf.Count = 0 then
    begin
      FRf.SnrMin := p.RxSnr;   FRf.SnrMax := p.RxSnr;
      FRf.RssiMin := p.RxRssi; FRf.RssiMax := p.RxRssi;
    end
    else
    begin
      if p.RxSnr < FRf.SnrMin then FRf.SnrMin := p.RxSnr;
      if p.RxSnr > FRf.SnrMax then FRf.SnrMax := p.RxSnr;
      if p.RxRssi < FRf.RssiMin then FRf.RssiMin := p.RxRssi;
      if p.RxRssi > FRf.RssiMax then FRf.RssiMax := p.RxRssi;
    end;
    FRf.SnrLast := p.RxSnr;   FRf.SnrSum := FRf.SnrSum + p.RxSnr;
    FRf.RssiLast := p.RxRssi; FRf.RssiSum := FRf.RssiSum + p.RxRssi;
    Inc(FRf.Count);
  end;

  if not p.HasDecoded then
  begin
    if p.Encrypted and Assigned(FOnDebug) then
      FOnDebug(Format('[encrypted packet from %s on ch %d]',
        [NodeLabel(p.FromNum), p.Channel]));
    Exit;
  end;

  case p.Decoded.Portnum of
    PORT_TEXT_MESSAGE_APP:
      begin
        SetLength(txt, Length(p.Decoded.Payload));
        if Length(p.Decoded.Payload) > 0 then
          Move(p.Decoded.Payload[0], txt[1], Length(p.Decoded.Payload));
        direct := (FMyNum <> 0) and (p.ToNum = FMyNum);
        if Assigned(FOnText) then
          FOnText(p.FromNum, p.ToNum, p.Channel, txt, direct,
                  p.HopLimit, p.HopStart);
      end;

    PORT_TRACEROUTE_APP:
      begin
        rd := DecodeRouteDiscovery(p.Decoded.Payload);
        line := Format('Traceroute reply from %s:', [NodeLabel(p.FromNum)]);
        line := line + LineEnding + '  ' + NodeLabel(FMyNum) + ' (you)';
        for i := 0 to High(rd.Route) do
        begin
          line := line + LineEnding + '  -> ' + NodeLabel(rd.Route[i]);
          if i <= High(rd.SnrTowards) then
            line := line + Format('  (SNR %.2f dB)', [rd.SnrTowards[i] / 4]);
        end;
        line := line + LineEnding + '  -> ' + NodeLabel(p.FromNum) + ' (target)';
        if Length(rd.RouteBack) > 0 then
        begin
          line := line + LineEnding + '  return path:';
          for i := 0 to High(rd.RouteBack) do
            line := line + LineEnding + '  <- ' + NodeLabel(rd.RouteBack[i]);
        end;
        if Assigned(FOnTrace) then FOnTrace(line);
      end;

    PORT_ROUTING_APP:
      begin
        if (p.Decoded.RequestId <> 0) and TakePending(p.Decoded.RequestId) then
        begin
          if DecodeRoutingError(p.Decoded.Payload, code) then
          begin
            if Assigned(FOnAck) then FOnAck(p.Decoded.RequestId, code = 0, code);
          end
          else if Assigned(FOnAck) then
            FOnAck(p.Decoded.RequestId, True, 0);
        end;
      end;

    PORT_TELEMETRY_APP:
      begin
        { Only surface telemetry addressed to us (a reply to /info); ignore the
          periodic telemetry broadcasts other nodes send to everyone. }
        if (FMyNum <> 0) and (p.ToNum = FMyNum) and Assigned(FOnTelemetry) then
          FOnTelemetry(p.FromNum, DecodeTelemetry(p.Decoded.Payload));
      end;

    PORT_NODEINFO_APP:
      begin
        { A NodeInfo reply addressed to us (a response to /whois). Learn the name
          immediately and report it. Broadcast NodeInfos still flow in through
          the normal node database path. }
        if (FMyNum <> 0) and (p.ToNum = FMyNum) then
        begin
          u := DecodeUser(p.Decoded.Payload, 0, Length(p.Decoded.Payload));
          SetNodeUser(p.FromNum, u);
          if Assigned(FOnNodeInfo) then FOnNodeInfo(p.FromNum, u.ShortName, u.LongName);
        end;
      end;
  end;
end;

procedure TMeshClient.HandleFromRadio(const b: TBytes);
var
  fr: TFromRadio;
begin
  fr := DecodeFromRadio(b);
  case fr.Kind of
    frMyInfo:
      FMyNum := fr.MyNodeNum;
    frNodeInfo:
      begin
        UpsertNode(fr.Node);
        if Assigned(FOnNode) then FOnNode(fr.Node);
      end;
    frChannel:
      SetChannel(fr.Channel);
    frConfigComplete:
      begin
        { The id echoes our nonce. A mismatch is the tail of an earlier
          session's dump still draining out of the radio - not our config. }
        if fr.ConfigCompleteId = FNonce then
        begin
          FConfigDone := True;
          if Assigned(FOnConfig) then
            FOnConfig(Format('Config complete: %d nodes, %d channels, my node %s',
              [Length(FNodes), Length(FChannels), NodeLabel(FMyNum)]));
        end
        else if Assigned(FOnConfig) then
          FOnConfig('Ignored a stale config-complete from an earlier session');
      end;
    frPacket:
      HandlePacket(fr.Packet);
    frLogRecord:
      if Assigned(FOnDebug) and (fr.LogText <> '') then
        FOnDebug('[dev] ' + fr.LogText);
  end;
end;

procedure TMeshClient.MaybeHeartbeat;
begin
  if (FT = nil) or (not FT.IsOpen) then Exit;
  if (Now - FLastBeat) * 86400.0 >= HEARTBEAT_SECS then
  begin
    try FT.Send(EncodeHeartbeat); except end;
    FLastBeat := Now;
  end;
end;

procedure TMeshClient.Poll;
var
  b: TBytes;
  s: string;
begin
  while FT.TryGetPacket(b) do
    HandleFromRadio(b);
  while FT.TryGetDebug(s) do
    if Assigned(FOnDebug) then FOnDebug(s);
  MaybeHeartbeat;
end;

{ ---- queries ---- }

function TMeshClient.NodeCount: Integer;
begin
  Result := Length(FNodes);
end;

function TMeshClient.GetNode(i: Integer): TMeshNode;
begin
  Result := FNodes[i];
end;

function TMeshClient.ChannelCount: Integer;
begin
  Result := Length(FChannels);
end;

function TMeshClient.GetChannel(i: Integer): TChannelInfo;
begin
  Result := FChannels[i];
end;

function TMeshClient.MyNum: LongWord;
begin
  Result := FMyNum;
end;

function TMeshClient.RfStats: TRfStats;
begin
  Result := FRf;
end;

function TMeshClient.ConfigComplete: Boolean;
begin
  Result := FConfigDone;
end;

function TMeshClient.NodeLabel(num: LongWord): string;
var
  idx: Integer;
begin
  if num = BROADCAST_ADDR then Exit('^all');
  if num = 0 then Exit('(unknown)');
  idx := NodeIndex(num);
  if (idx >= 0) and FNodes[idx].HasUser and (FNodes[idx].User.ShortName <> '') then
  begin
    if FShowIds then
      Result := Format('%s (%s)', [FNodes[idx].User.ShortName, NodeNumToId(num)])
    else
      Result := FNodes[idx].User.ShortName;    { short name alone (default) }
  end
  else
    Result := NodeNumToId(num);                { no name known yet: fall back to !id }
end;

function TMeshClient.ResolveTarget(const s: string; out num: LongWord): Boolean;
var
  i: Integer;
  t: string;
begin
  if TryParseNodeId(s, num) then Exit(True);
  t := Trim(s);
  { match by short or long name, case-insensitive }
  for i := 0 to High(FNodes) do
    if FNodes[i].HasUser then
      if SameText(FNodes[i].User.ShortName, t) or
         SameText(FNodes[i].User.LongName, t) then
      begin
        num := FNodes[i].Num;
        Exit(True);
      end;
  Result := False;
end;

{ ---- sending ---- }

function TMeshClient.SendText(dest: LongWord; channel: Integer;
  const text: string; wantAck: Boolean): LongWord;
begin
  Result := RandId;
  FT.Send(EncodeTextPacket(dest, channel, wantAck, Result, text));
  if wantAck then AddPending(Result);
end;

function TMeshClient.SendTraceroute(dest: LongWord; channel, hopLimit: Integer): LongWord;
begin
  Result := RandId;
  FT.Send(EncodeTraceroutePacket(dest, channel, hopLimit, Result));
end;

function TMeshClient.SendTelemetryRequest(dest: LongWord; channel: Integer): LongWord;
begin
  Result := RandId;
  FT.Send(EncodeTelemetryPacket(dest, channel, Result));
end;

function TMeshClient.SendNodeInfoRequest(dest: LongWord; channel: Integer): LongWord;
begin
  Result := RandId;
  FT.Send(EncodeNodeInfoPacket(dest, channel, Result, NodeNumToId(FMyNum)));
end;

end.
