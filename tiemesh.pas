program tiemesh;
{
  A terminal Meshtastic client.

  Features:
    * connects to a radio over serial (or BLE, see below)
    * node list            /nodes
    * channel list         /channels
    * direct messages      /dm <target> <text>   (or set a default with /to)
    * channel messages     just type text (goes to the current channel)
    * traceroute           /trace <target>
    * node telemetry        /info <target>
    * clear screen but keep a full log   /clear   (log kept in memory + file)
    * replay the log       /log [n]

  Build (serial only, all platforms):
      fpc tiemesh.pas

  Build with the Linux BLE transport as well:
      fpc -dMESH_BLE tiemesh.pas        (requires BlueZ; see meshble.pas)

  Run:
      ./tiemesh --serial /dev/ttyACM0
      ./tiemesh --serial COM5
      ./tiemesh --ble AA:BB:CC:DD:EE:FF     (only if built with -dMESH_BLE)

  The on-screen log is colourised; pass --no-colour to disable it (the log FILE
  is always plain text regardless).

  A radio speaks this protobuf protocol on its USB serial port out of the box;
  no special device configuration is required for the serial client API.
}
{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}   { cthreads MUST be first }
  SysUtils, DateUtils, Crt,
  MeshProto, MeshTransport, MeshClient
  {$IFDEF MESH_BLE}, MeshBLE{$ENDIF};

const
  PROMPT = '> ';
  VERNUM = 0.01;                  { tiemesh version number }
  COMPDATE = {$I %DATE%};         { compile date, stamped in by the compiler }

var
  Trans: ITransport;
  Client: TMeshClient;
  Input: string = '';
  CursorPos: Integer = 0;       { 0..Length(Input): chars to the left of the cursor }
  Running: Boolean = True;
  Verbose: Boolean = False;
  NoColour: Boolean = False;    { --no-colour disables all ANSI colouring }
  ConfirmSends: Boolean = True; { ask 'send?' before transmitting a message }
  ShowIdsFlag: Boolean = False; { --show-ids: start with node ids alongside names }
  BellOn: Boolean = True;       { audible notification on an incoming message }
  BellCmd: string = '';         { --bell-cmd: external player instead of the bell }
  CurChannel: Integer = 0;      { channel index used for outgoing messages }
  HaveTarget: Boolean = False;
  Target: LongWord = 0;         { default DM target, if set }
  LogFile: Text;
  LogFileOpen: Boolean = False;
  SessionLog: array of string;  { this session's coloured message lines, for bare /log }
  DebugFile: Text;
  DebugFileOpen: Boolean = False;
  LogPath: string;            { full path to the message log (set at startup) }
  DebugPath: string;          { full path to the debug log (set at startup) }
  History: array of string;   { last dozen submitted lines, oldest first }
  HistIndex: Integer = 0;     { cursor into History; = Length(History) means "new line" }
  Scratch: string = '';       { in-progress line, saved while browsing history }

{ ------------------------------------------------------------------ }
{ logging + console output                                            }
{ ------------------------------------------------------------------ }

const
  { The CRT unit runs the terminal in raw mode and does NOT pass embedded ANSI
    escape codes through, so colour must go through CRT's own TextColor(). We
    encode colour in-band with a marker byte that WriteColoured() translates
    into TextColor calls; the log file stores the plain text with markers removed. }
  { Colour is applied via CRT's TextColor(), so all 16 CRT colours are available.
    Each field gets its own colour so they're visually separable. }
  C_TIME = Green;      { timestamps }
  C_NAME = Cyan;       { node names / !ids }
  C_TAG  = Magenta;    { DM / channel tags }
  C_TEXT = LightGray;  { message text }
  C_HOPS = DarkGray;   { hop counts (the darkest, most-receding slot) }
  C_SNR  = Brown;      { SNR values in traceroute }
  C_ACK  = LightBlue;  { acknowledgements }
  C_META = Yellow;     { status / config lines, listing headers }
  C_ERR  = LightRed;   { failures (undelivered messages) }
  C_BANNER = LightCyan;{ startup / version banner }
  CLR_MARK = #1;       { in-band marker: CLR_MARK + Chr(colour); colour 255 = reset }
  LINK_MARK = #2;      { in-band marker: LINK_MARK + url + LINK_MARK wraps a hyperlink }

{ Remove colour markers, yielding plain text (for the log file). }
function StripMarkup(const s: string): string;
var
  i: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(s) do
    if (s[i] = CLR_MARK) and (i < Length(s)) then Inc(i, 2)   { drop colour marker + byte }
    else if s[i] = LINK_MARK then Inc(i)                       { drop link marker, keep URL text }
    else begin Result := Result + s[i]; Inc(i); end;
end;

{ Write bytes straight to the terminal, bypassing CRT (which would eat escape
  sequences). Used only for the OSC 8 hyperlink codes; visible text still goes
  through CRT so it stays coloured and positioned. }
procedure RawTermOut(const s: string);
begin
  if s = '' then Exit;
  {$IFDEF UNIX}
  fpWrite(1, s[1], Length(s));   { fd 1 = stdout }
  {$ELSE}
  Write(s);
  {$ENDIF}
end;

{ Wrap http(s):// URLs in a plain string with LINK_MARK so WriteColoured emits
  them as OSC 8 terminal hyperlinks. Trailing sentence punctuation is left out
  of the link. }
function LinkifyURLs(const s: string): string;
var
  i, j: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(s) do
  begin
    if (LowerCase(Copy(s, i, 7)) = 'http://') or (LowerCase(Copy(s, i, 8)) = 'https://') then
    begin
      j := i;
      while (j <= Length(s)) and (s[j] > ' ') and (Ord(s[j]) < 127) do Inc(j);
      while (j > i) and (s[j - 1] in ['.', ',', ')', ']', '}', '!', '?', ';', ':', '"', '''']) do
        Dec(j);
      Result := Result + LINK_MARK + Copy(s, i, j - i) + LINK_MARK;
      i := j;
    end
    else
    begin
      Result := Result + s[i];
      Inc(i);
    end;
  end;
end;

{ Write a marked-up string to the screen, translating markers to TextColor. }
procedure WriteColoured(const s: string);
var
  i, runStart, j: Integer;
  cb: Byte;
  url: string;
begin
  i := 1;
  runStart := 1;
  while i <= Length(s) do
  begin
    if (s[i] = CLR_MARK) and (i < Length(s)) then
    begin
      if i > runStart then Write(Copy(s, runStart, i - runStart));
      cb := Ord(s[i + 1]);
      if cb = 255 then NormVideo else TextColor(cb);
      Inc(i, 2);
      runStart := i;
    end
    else if s[i] = LINK_MARK then
    begin
      if i > runStart then Write(Copy(s, runStart, i - runStart));
      j := i + 1;
      while (j <= Length(s)) and (s[j] <> LINK_MARK) do Inc(j);
      url := Copy(s, i + 1, j - i - 1);
      { OSC 8 hyperlink: start code (raw, bypassing CRT), visible URL via CRT
        so it keeps its colour, then the end code (raw). }
      Flush(Output);
      RawTermOut(#27']8;;' + url + #7);
      Write(url);
      Flush(Output);
      RawTermOut(#27']8;;'#7);
      i := j + 1;
      runStart := i;
    end
    else
      Inc(i);
  end;
  if i > runStart then Write(Copy(s, runStart, i - runStart));
  NormVideo;
end;

const
  SESSIONLOG_MAX = 1000;   { cap the in-memory session log to bound memory }

{ Writes a line to the persistent log file (plain, colour markers removed so it
  stays greppable) and appends the coloured display line to this session's log,
  which bare /log replays. }
procedure AddLog(const plainText, displayText: string);
var
  j: Integer;
begin
  SetLength(SessionLog, Length(SessionLog) + 1);
  SessionLog[High(SessionLog)] := displayText;
  if Length(SessionLog) > SESSIONLOG_MAX then
  begin
    for j := 0 to High(SessionLog) - 1 do
      SessionLog[j] := SessionLog[j + 1];
    SetLength(SessionLog, SESSIONLOG_MAX);
  end;
  if LogFileOpen then
  begin
    Writeln(LogFile, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), '  ', StripMarkup(plainText));
    Flush(LogFile);
  end;
end;

{ wipe the current input line so an async message can be printed cleanly }
procedure BeginAsync;
begin
  Write(#13);   { carriage return -> column 1 }
  ClrEol;
end;

procedure DrawPrompt;
begin
  Write(PROMPT, Input);
  { put the cursor back where the user is editing (not always the end) }
  GotoXY(Length(PROMPT) + CursorPos + 1, WhereY);
end;

{ display only (does not touch the log) }
procedure Show(const s: string);
begin
  BeginAsync;
  WriteColoured(s);
  Writeln;
  DrawPrompt;
end;

{ display + log (plain, no colour) }
procedure Emit(const s: string);
begin
  BeginAsync;
  WriteColoured(s);
  Writeln;
  DrawPrompt;
  AddLog(s, s);
end;

{ display a colourised line but log/replay accordingly: displayText on screen and
  in /log, plainText in the file }
procedure EmitColoured(const plainText, displayText: string);
begin
  BeginAsync;
  WriteColoured(displayText);
  Writeln;
  DrawPrompt;
  AddLog(plainText, displayText);
end;

{ Wrap s in a colour marker, unless --no-colour is set (then return s unchanged). }
function Paint(colour: Byte; const s: string): string;
begin
  if NoColour then Result := s
  else Result := CLR_MARK + Chr(colour) + s + CLR_MARK + Chr(255);
end;

{ Emit a whole line in one colour (plain text still goes to the log file). }
procedure EmitPainted(colour: Byte; const s: string);
begin
  EmitColoured(s, Paint(colour, s));
end;

{ Show a whole line in one colour (not logged). }
procedure ShowPainted(colour: Byte; const s: string);
begin
  Show(Paint(colour, s));
end;

function BannerText: string;
begin
  Result := Format('TieMesh %.2f  compiled on %s', [VERNUM, COMPDATE]);
end;

{ Remove ANSI/VT100 escape sequences (the radio colourises its debug output). }
function StripAnsi(const s: string): string;
var
  i: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(s) do
  begin
    if s[i] = #27 then                { ESC }
    begin
      Inc(i);
      if (i <= Length(s)) and (s[i] = '[') then
      begin
        Inc(i);
        while (i <= Length(s)) and not (s[i] in ['A'..'Z', 'a'..'z']) do Inc(i);
        if i <= Length(s) then Inc(i);   { skip the final command letter }
      end;
    end
    else
    begin
      Result := Result + s[i];
      Inc(i);
    end;
  end;
end;

{ Device debug console text. Kept OUT of the main message log so that /log stays
  readable. Only surfaces when --verbose/`/verbose` is on, and then goes to a
  separate ~/tiemesh-debug.log, never the main log. }
procedure DebugLog(const raw: string);
var
  s: string;
begin
  if not Verbose then Exit;
  s := StripAnsi(raw);
  BeginAsync;
  Writeln('. ', s);
  DrawPrompt;
  if not DebugFileOpen then
  begin
    try
      AssignFile(DebugFile, DebugPath);
      if FileExists(DebugPath) then Append(DebugFile) else Rewrite(DebugFile);
      DebugFileOpen := True;
    except
      DebugFileOpen := False;
    end;
  end;
  if DebugFileOpen then
  begin
    Writeln(DebugFile, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), '  ', s);
    Flush(DebugFile);
  end;
end;

{ Track ids of public (broadcast) messages we sent with want_ack, so that when
  the implicit ACK comes back we can word it as "acknowledged" rather than the
  DM wording "delivered". A broadcast ACK means at least one node rebroadcast it. }
var
  BcastIds: array of LongWord;

procedure AddBcast(id: LongWord);
begin
  SetLength(BcastIds, Length(BcastIds) + 1);
  BcastIds[High(BcastIds)] := id;
end;

{ Returns True (and removes the id) if it was one of our broadcasts. }
function IsBcast(id: LongWord): Boolean;
var
  i, j: Integer;
begin
  Result := False;
  for i := 0 to High(BcastIds) do
    if BcastIds[i] = id then
    begin
      for j := i to High(BcastIds) - 1 do
        BcastIds[j] := BcastIds[j + 1];
      SetLength(BcastIds, Length(BcastIds) - 1);
      Exit(True);
    end;
end;

{ ------------------------------------------------------------------ }
{ client event callbacks                                             }
{ ------------------------------------------------------------------ }

type
  THandlers = class
    procedure OnText(fromNum, toNum: LongWord; channel: Integer;
      const text: string; direct: Boolean; hopLimit, hopStart: Integer);
    procedure OnTrace(const line: string);
    procedure OnDebug(const line: string);
    procedure OnNode(const node: TMeshNode);
    procedure OnConfig(const line: string);
    procedure OnAck(reqId: LongWord; success: Boolean; code: Integer);
    procedure OnTelemetry(fromNum: LongWord; const t: TTelemetry);
    procedure OnNodeInfo(fromNum: LongWord; const shortName, longName: string);
  end;

{ Audible notification for an incoming message. The default is the terminal
  bell, written straight to the terminal (CRT would swallow it). Over SSH the
  bell rings on YOUR terminal, not the remote machine, which is what you want
  when the radio is on a Pi. A DM gets a second beep so you can tell it apart
  from channel traffic without looking. --bell-cmd runs an external player
  instead, e.g. --bell-cmd "aplay /home/me/alert.wav". }
procedure NotifySound(direct: Boolean);
begin
  if not BellOn then Exit;
  if BellCmd <> '' then
  begin
    try
      { trailing & so the player runs in the background and never blocks the UI }
      ExecuteProcess('/bin/sh', ['-c', BellCmd + ' >/dev/null 2>&1 &']);
    except
      { a failing sound command must never take the client down }
    end;
    Exit;
  end;
  RawTermOut(#7);
  if direct then
  begin
    Sleep(80);
    RawTermOut(#7);
  end;
end;

procedure THandlers.OnText(fromNum, toNum: LongWord; channel: Integer;
  const text: string; direct: Boolean; hopLimit, hopStart: Integer);
var
  tag, hopStr, ts, nameLabel: string;
  hops: Integer;
begin
  if direct then tag := ' (DM)'
  else if channel > 0 then tag := Format(' [ch %d]', [channel])
  else tag := '';

  { hops travelled = hop_start - hop_limit. hop_start = 0 means the sending
    node's firmware didn't stamp it (older firmware), so the count is unknown.
    In that case we still show hop_limit, which is informative on its own. }
  if hopStart > 0 then
  begin
    hops := hopStart - hopLimit;
    if hops < 0 then hops := 0;
    if hops = 0 then hopStr := '  (0 hops, direct)'
    else if hops = 1 then hopStr := '  (1 hop)'
    else hopStr := Format('  (%d hops)', [hops]);
  end
  else
    hopStr := '  (hops unknown)';   { sender's firmware didn't stamp hop_start }

  ts := FormatDateTime('hh:nn', Now);
  nameLabel := Client.NodeLabel(fromNum);

  { plain line -> log file (greppable); coloured line -> screen and /log }
  EmitColoured(
    Format('[%s] %s%s: %s%s', [ts, nameLabel, tag, text, hopStr]),
    Paint(C_TIME, '[' + ts + ']') + ' ' +
    Paint(C_NAME, nameLabel) + Paint(C_TAG, tag) + ': ' +
    Paint(C_TEXT, LinkifyURLs(text)) + Paint(C_HOPS, hopStr));

  NotifySound(direct);
end;

procedure THandlers.OnTrace(const line: string);
var
  i, start, sp: Integer;
  sub, colOut: string;
begin
  { The trace arrives as a multi-line string. Colour each line: node/route text
    cyan, any "(SNR ...)" portion dark grey. Plain original still logged to file. }
  colOut := '';
  start := 1;
  for i := 1 to Length(line) + 1 do
    if (i > Length(line)) or (line[i] = #10) then
    begin
      sub := Copy(line, start, i - start);
      if (Length(sub) > 0) and (sub[Length(sub)] = #13) then
        SetLength(sub, Length(sub) - 1);          { tolerate CRLF }
      sp := Pos('  (SNR', sub);
      if sp > 0 then
        colOut := colOut + Paint(C_NAME, Copy(sub, 1, sp - 1)) +
                  Paint(C_SNR, Copy(sub, sp, MaxInt))
      else
        colOut := colOut + Paint(C_NAME, sub);
      if i <= Length(line) then colOut := colOut + LineEnding;
      start := i + 1;
    end;
  EmitColoured(line, colOut);
end;

procedure THandlers.OnDebug(const line: string);
begin
  DebugLog(line);
end;

procedure THandlers.OnNode(const node: TMeshNode);
begin
  if Verbose then
    EmitPainted(C_NAME, 'node: ' + Client.NodeLabel(node.Num));
end;

procedure THandlers.OnConfig(const line: string);
begin
  EmitPainted(C_META, line);
end;

{ Human-readable Routing.Error names (mesh.proto). The device generates these
  locally as well as receiving them from the mesh. }
function RoutingErrorName(code: Integer): string;
begin
  case code of
    0:  Result := 'NONE';
    1:  Result := 'NO_ROUTE (no path to that node)';
    2:  Result := 'GOT_NAK (a node rejected it)';
    3:  Result := 'TIMEOUT';
    4:  Result := 'NO_INTERFACE';
    5:  Result := 'MAX_RETRANSMIT (no ack after 3 retries - it may still have arrived)';
    6:  Result := 'NO_CHANNEL (no suitable channel for this packet)';
    7:  Result := 'TOO_LARGE (message too big)';
    8:  Result := 'NO_RESPONSE';
    9:  Result := 'DUTY_CYCLE_LIMIT (regional airtime limit reached)';
    32: Result := 'BAD_REQUEST';
    33: Result := 'NOT_AUTHORIZED (wrong channel for that node)';
    34: Result := 'PKI_FAILED';
    35: Result := 'PKI_UNKNOWN_PUBKEY (no public key known for that node)';
    36: Result := 'ADMIN_BAD_SESSION_KEY';
    37: Result := 'ADMIN_PUBLIC_KEY_UNAUTHORIZED';
  else
    Result := Format('error %d', [code]);
  end;
end;

procedure THandlers.OnAck(reqId: LongWord; success: Boolean; code: Integer);
var
  idStr: string;
begin
  idStr := LowerCase(IntToHex(reqId, 8));
  if success then
  begin
    if IsBcast(reqId) then
      EmitPainted(C_ACK, Format('ack: message %s acknowledged (heard on the mesh)', [idStr]))
    else
      EmitPainted(C_ACK, Format('ack: message %s delivered', [idStr]));
  end
  else
  begin
    IsBcast(reqId);   { drop it from the tracking list either way }
    EmitPainted(C_ERR, Format('ack: message %s NOT delivered - %s', [idStr, RoutingErrorName(code)]));
  end;
end;

function FmtUptime(secs: LongWord): string;
var
  d, h, m: LongWord;
begin
  d := secs div 86400;
  h := (secs mod 86400) div 3600;
  m := (secs mod 3600) div 60;
  if d > 0 then Result := Format('%dd %dh %dm', [d, h, m])
  else if h > 0 then Result := Format('%dh %dm', [h, m])
  else Result := Format('%dm', [m]);
end;

procedure THandlers.OnTelemetry(fromNum: LongWord; const t: TTelemetry);

  procedure Field(const lbl, val: string);
  begin
    EmitColoured('  ' + lbl + ': ' + val,
      '  ' + Paint(C_NAME, lbl) + ': ' + Paint(C_TEXT, val));
  end;

var
  batt, hdr: string;
begin
  hdr := 'Telemetry from ' + Client.NodeLabel(fromNum) + ':';
  EmitColoured(hdr, Paint(C_META, hdr));

  if t.HasDevice then
    with t.Device do
    begin
      if HasBattery then
      begin
        if Battery > 100 then batt := 'powered (external)'
        else batt := IntToStr(Battery) + '%';
        Field('battery', batt);
      end;
      if HasVoltage then Field('voltage', Format('%.2f V', [Voltage]));
      if HasChanUtil then Field('channel util', Format('%.1f%%', [ChanUtil]));
      if HasAirTx then Field('air util tx', Format('%.1f%%', [AirTx]));
      if HasUptime then Field('uptime', FmtUptime(Uptime));
    end;

  if t.HasEnv then
    with t.Env do
    begin
      if HasTemp then Field('temperature', Format('%.1f C', [Temp]));
      if HasHumidity then Field('humidity', Format('%.1f%%', [Humidity]));
      if HasPressure then Field('pressure', Format('%.1f hPa', [Pressure]));
      if HasGas then Field('gas resistance', Format('%.0f', [Gas]));
    end;

  if (not t.HasDevice) and (not t.HasEnv) then
    EmitColoured('  (no metrics in reply)', Paint(C_META, '  (no metrics in reply)'));
end;

procedure THandlers.OnNodeInfo(fromNum: LongWord; const shortName, longName: string);
var
  nm: string;
begin
  if shortName <> '' then nm := shortName else nm := '(no short name)';
  if longName <> '' then nm := nm + ' - ' + longName;
  EmitPainted(C_META, Format('node info: %s is %s', [NodeNumToId(fromNum), nm]));
end;

var
  Handlers: THandlers;

{ ------------------------------------------------------------------ }
{ commands                                                           }
{ ------------------------------------------------------------------ }

{ ------------------------------------------------------------------ }
{ screen pager: shows lines and pauses when the screen fills          }
{ ------------------------------------------------------------------ }

type
  TPager = record
    PageSize: Integer;
    Count: Integer;
    Stopped: Boolean;
  end;

procedure PagerInit(out p: TPager);
var
  rows: Integer;
begin
  rows := Hi(WindMax) + 1;                      { terminal height in rows }
  if (rows < 5) or (rows > 300) then rows := 24;
  p.PageSize := rows - 1;                        { leave a line for the prompt }
  p.Count := 0;
  p.Stopped := False;
end;

{ Print s through the pager. Pauses before printing when a page is full.
  Returns False if the user chose to stop (prompt already redrawn). }
function PagerLine(var p: TPager; const s: string): Boolean;
var
  c: Char;
begin
  if p.Stopped then Exit(False);
  if p.Count >= p.PageSize then
  begin
    Write(#13); ClrEol;             { erase the "> " prompt Show just drew }
    Write('  -- more -- (any key to continue, q to stop) ');
    c := ReadKey;
    if c = #0 then ReadKey;         { discard 2nd byte of an extended key }
    Write(#13); ClrEol;             { erase the prompt line }
    if (c = 'q') or (c = 'Q') or (c = #3) or (c = #27) then
    begin
      p.Stopped := True;
      DrawPrompt;
      Exit(False);
    end;
    p.Count := 0;
  end;
  Show(s);
  Inc(p.Count);
  Result := True;
end;

procedure CmdHelp;
begin
  Show('Commands:');
  Show('  /nodes                 list known nodes');
  Show('  /channels              list channels');
  Show('  /dm <target> <text>    send a direct message');
  Show('  /trace <target>        run a traceroute');
  Show('  /info <target>         request telemetry (battery, uptime, etc.)');
  Show('  /whois <target>        request a node''s name (short/long)');
  Show('  /to <target>           set default DM target (blank = broadcast)');
  Show('  /ch <index>            set outgoing channel index');
  Show('  /clear                 clear the screen (log is kept)');
  Show('  /log                   replay this session''s messages');
  Show('  /log <n>               show the last n lines from the log file');
  Show('  /verbose               toggle device debug output');
  Show('  /version               show version and compile date');
  Show('  /confirm               toggle the send-confirmation prompt');
  Show('  /names                 toggle short names / short names with !ids');
  Show('  /hops [n]              show or set the outgoing hop limit (1..7)');
  Show('  /bell                  toggle the incoming-message sound');
  Show('  /quit                  disconnect and exit');
  Show('  <text>                 send to current target/channel');
  Show(Format('Target: %s   Channel: %d',
    [BoolToStr(HaveTarget, Client.NodeLabel(Target), 'broadcast'), CurChannel]));
end;

function AgeStr(lastHeard: LongWord): string;
var
  nowU: Int64;
  age: Int64;
begin
  if lastHeard = 0 then Exit('   -');
  nowU := DateTimeToUnix(Now);
  age := nowU - Int64(lastHeard);
  if age < 0 then age := 0;
  if age < 120 then Result := Format('%ds', [age])
  else if age < 7200 then Result := Format('%dm', [age div 60])
  else Result := Format('%dh', [age div 3600]);
end;

procedure CmdNodes;
var
  i: Integer;
  n: TMeshNode;
  nm, hops, snr, bat: string;
  p: TPager;
begin
  PagerInit(p);
  if not PagerLine(p, Paint(C_META, Format('Known nodes: %d', [Client.NodeCount]))) then Exit;
  if not PagerLine(p, Paint(C_META, '  short  id          hops  snr     batt  age    name')) then Exit;
  if not PagerLine(p, Paint(C_META, '  -----  ----------  ----  ------  ----  -----  ----')) then Exit;

  for i := 0 to Client.NodeCount - 1 do
  begin
    n := Client.GetNode(i);
    if n.HasUser then nm := n.User.ShortName else nm := '';
    if n.HasHops then hops := IntToStr(n.HopsAway) else hops := '-';
    if n.Snr <> 0 then snr := Format('%.1f', [n.Snr]) else snr := '-';
    if n.HasBattery then bat := IntToStr(n.Battery) + '%' else bat := '-';
    if not PagerLine(p,
      '  ' + Paint(C_NAME, Format('%-5s', [nm])) +
      '  ' + Paint(C_NAME, Format('%-10s', [NodeNumToId(n.Num)])) +
      '  ' + Paint(C_HOPS, Format('%-4s', [hops])) +
      '  ' + Paint(C_SNR, Format('%-6s', [snr])) +
      '  ' + Paint(C_META, Format('%-4s', [bat])) +
      '  ' + Paint(C_META, Format('%-5s', [AgeStr(n.LastHeard)])) +
      '  ' + Paint(C_TEXT, Copy(n.User.LongName, 1, 24))) then Exit;
  end;
end;

procedure CmdChannels;
var
  i: Integer;
  c: TChannelInfo;
  role, nm: string;
begin
  Show(Paint(C_META, Format('Channels: %d', [Client.ChannelCount])));
  for i := 0 to Client.ChannelCount - 1 do
  begin
    c := Client.GetChannel(i);
    case c.Role of
      CH_ROLE_PRIMARY:   role := 'PRIMARY';
      CH_ROLE_SECONDARY: role := 'secondary';
      else               role := 'disabled';
    end;
    nm := c.Name;
    if (nm = '') and (c.Role = CH_ROLE_PRIMARY) then nm := '(default)';
    Show('  ' + Paint(C_NAME, Format('[%d]', [c.Index])) +
         ' ' + Paint(C_META, Format('%-9s', [role])) +
         ' ' + Paint(C_NAME, nm));
  end;
end;

{ Best-effort re-colourisation of a plain log-file line for /log <n> viewing.
  File lines look like: "yyyy-mm-dd hh:nn:ss  <original message>". Not perfect,
  but it restores the field colours for readability. }
{ Replace any bare "!aabbccdd" node id with that node's short name, when the node
  database knows it now. Log-file lines were written at the time the message
  arrived, which may have been before the node's NodeInfo (and therefore its
  name) was learned. An id already in brackets -- "zead (!e75b9c8e)" -- is left
  alone, since it is already annotated with a name. }
function PreferShortNames(const s: string): string;
var
  i, j: Integer;
  idTxt: string;
  num: LongWord;
begin
  Result := '';
  i := 1;
  while i <= Length(s) do
  begin
    if (s[i] = '!') and ((i = 1) or (s[i - 1] <> '(')) then
    begin
      j := i + 1;
      while (j <= Length(s)) and (j <= i + 8) and
            (s[j] in ['0'..'9', 'a'..'f', 'A'..'F']) do Inc(j);
      if j = i + 9 then                 { exactly 8 hex digits: a node id }
      begin
        idTxt := Copy(s, i, 9);
        if (Client <> nil) and Client.ResolveTarget(idTxt, num) then
          Result := Result + Client.NodeLabel(num)
        else
          Result := Result + idTxt;
        i := j;
        Continue;
      end;
    end;
    Result := Result + s[i];
    Inc(i);
  end;
end;

function ColouriseLogLine(const s: string): string;
var
  prefix, body, seg, suffix: string;
  pBracket, pColon, pHops, j: Integer;
begin
  if NoColour then Exit(PreferShortNames(s));

  { split off the file timestamp prefix (19 chars + 2 spaces) }
  if (Length(s) >= 21) and (s[5] = '-') and (s[11] = ' ') then
  begin
    prefix := Copy(s, 1, 19);
    body := Copy(s, 22, MaxInt);
    Result := Paint(C_TIME, prefix) + '  ';
  end
  else
  begin
    body := s;
    Result := '';
  end;

  { names may have been learned since the line was written }
  body := PreferShortNames(body);

  { message line: [HH:MM] name tag: text (hops) }
  if (Length(body) >= 1) and (body[1] = '[') then
  begin
    pBracket := Pos(']', body);
    pColon := 0;
    if pBracket > 0 then
    begin
      j := Pos(': ', Copy(body, pBracket + 1, MaxInt));
      if j > 0 then pColon := j + pBracket;
    end;
    if (pBracket > 0) and (pColon > 0) then
    begin
      Result := Result + Paint(C_TIME, Copy(body, 1, pBracket));
      seg := Copy(body, pBracket + 1, pColon - pBracket - 1);   { space + name + tag }
      Result := Result + Paint(C_NAME, seg) + ': ';
      body := Copy(body, pColon + 2, MaxInt);
      { find the trailing "  (…hops…)" suffix, if any }
      pHops := 0;
      for j := Length(body) - 2 downto 1 do
        if Copy(body, j, 3) = '  (' then
        begin
          suffix := Copy(body, j, MaxInt);
          if (Pos('hop', suffix) > 0) or (Pos('direct', suffix) > 0) or
             (Pos('unknown', suffix) > 0) then pHops := j;
          Break;
        end;
      if pHops > 0 then
        Result := Result + Paint(C_TEXT, LinkifyURLs(Copy(body, 1, pHops - 1))) +
                  Paint(C_HOPS, Copy(body, pHops, MaxInt))
      else
        Result := Result + Paint(C_TEXT, LinkifyURLs(body));
      Exit;
    end;
  end;

  { non-message lines }
  if Copy(body, 1, 4) = 'ack:' then
  begin
    if Pos('NOT delivered', body) > 0 then Result := Result + Paint(C_ERR, body)
    else Result := Result + Paint(C_ACK, body);
  end
  else if (Pos('Traceroute', body) > 0) or (Pos(' -> ', body) > 0) or (Pos('(SNR', body) > 0) then
  begin
    pHops := Pos('  (SNR', body);
    if pHops > 0 then
      Result := Result + Paint(C_NAME, Copy(body, 1, pHops - 1)) +
                Paint(C_SNR, Copy(body, pHops, MaxInt))
    else
      Result := Result + Paint(C_NAME, body);
  end
  else
    Result := Result + Paint(C_META, body);
end;

procedure CmdLog(const arg: string);
var
  n, i, code, total, shown, idx: Integer;
  p: TPager;
  f: Text;
  ln: string;
  ring: array of string;
begin
  { bare "/log" -> replay THIS session's coloured messages (live, like before) }
  if Trim(arg) = '' then
  begin
    PagerInit(p);
    if not PagerLine(p, Paint(C_META,
      Format('--- this session: %d line(s) ---', [Length(SessionLog)]))) then Exit;
    for i := 0 to High(SessionLog) do
      if not PagerLine(p, SessionLog[i]) then Exit;
    PagerLine(p, Paint(C_META, '--- end of session ---'));
    Exit;
  end;

  { "/log <n>" -> last n lines from the persistent file, re-colourised }
  Val(Trim(arg), n, code);
  if (code <> 0) or (n <= 0) then n := 20;

  if LogFileOpen then Flush(LogFile);   { make sure recent lines are on disk }
  SetLength(ring, n);
  total := 0;
  {$I-}
  AssignFile(f, LogPath);
  Reset(f);
  {$I+}
  if IOResult <> 0 then
  begin
    ShowPainted(C_META, 'no log file yet at ' + LogPath);
    Exit;
  end;
  while not Eof(f) do
  begin
    ReadLn(f, ln);
    ring[total mod n] := ln;
    Inc(total);
  end;
  CloseFile(f);

  shown := total;
  if shown > n then shown := n;

  PagerInit(p);
  if not PagerLine(p, Paint(C_META,
    Format('--- last %d log lines (of %d) from %s ---', [shown, total, LogPath]))) then Exit;
  for i := 0 to shown - 1 do
  begin
    idx := (total - shown + i) mod n;
    if not PagerLine(p, ColouriseLogLine(ring[idx])) then Exit;
  end;
  PagerLine(p, Paint(C_META, '--- end of log ---'));
end;

procedure DoSendText(const text: string);
var
  id: LongWord;
  ts, lbl: string;
begin
  if text = '' then Exit;
  ts := FormatDateTime('hh:nn', Now);
  if HaveTarget then
  begin
    Client.SendText(Target, CurChannel, text, True);   { DM: explicit ack }
    lbl := Client.NodeLabel(Target);
    EmitColoured(
      Format('[%s] you -> %s: %s', [ts, lbl, text]),
      Paint(C_TIME, '[' + ts + ']') + ' ' +
      Paint(C_NAME, 'you -> ' + lbl) + ': ' + Paint(C_TEXT, LinkifyURLs(text)));
  end
  else
  begin
    { Public message: set want_ack so the radio reports the implicit ACK
      (generated when it hears a node rebroadcast our packet). }
    id := Client.SendText(BROADCAST_ADDR, CurChannel, text, True);
    AddBcast(id);
    EmitColoured(
      Format('[%s] you [ch %d]: %s', [ts, CurChannel, text]),
      Paint(C_TIME, '[' + ts + ']') + ' ' +
      Paint(C_NAME, 'you') + Paint(C_TAG, Format(' [ch %d]', [CurChannel])) +
      ': ' + Paint(C_TEXT, LinkifyURLs(text)));
  end;
end;

procedure DoDM(const rest: string);
var
  sp: Integer;
  who, msg, ts, lbl: string;
  num: LongWord;
begin
  sp := Pos(' ', rest);
  if sp = 0 then
  begin
    ShowPainted(C_META, 'usage: /dm <target> <text>');
    Exit;
  end;
  who := Copy(rest, 1, sp - 1);
  msg := Trim(Copy(rest, sp + 1, Length(rest)));
  if not Client.ResolveTarget(who, num) then
  begin
    ShowPainted(C_META, 'unknown node: ' + who);
    Exit;
  end;
  Client.SendText(num, CurChannel, msg, True);
  ts := FormatDateTime('hh:nn', Now);
  lbl := Client.NodeLabel(num);
  EmitColoured(
    Format('[%s] you -> %s: %s', [ts, lbl, msg]),
    Paint(C_TIME, '[' + ts + ']') + ' ' +
    Paint(C_NAME, 'you -> ' + lbl) + ': ' + Paint(C_TEXT, LinkifyURLs(msg)));
end;

procedure DoTrace(const who: string);
var
  num: LongWord;
begin
  if not Client.ResolveTarget(who, num) then
  begin
    ShowPainted(C_META, 'unknown node: ' + who);
    Exit;
  end;
  Client.SendTraceroute(num, CurChannel, 0);   { 0 -> DefaultHopLimit }
  EmitPainted(C_META, 'traceroute sent to ' + Client.NodeLabel(num) + ' (waiting for reply...)');
end;

procedure DoInfo(const who: string);
var
  num: LongWord;
begin
  if not Client.ResolveTarget(who, num) then
  begin
    ShowPainted(C_META, 'unknown node: ' + who);
    Exit;
  end;
  Client.SendTelemetryRequest(num, CurChannel);
  EmitPainted(C_META, 'requesting telemetry from ' + Client.NodeLabel(num) + ' (waiting for reply...)');
end;

procedure DoWhois(const who: string);
var
  num: LongWord;
begin
  if not Client.ResolveTarget(who, num) then
  begin
    ShowPainted(C_META, 'unknown node: ' + who);
    Exit;
  end;
  Client.SendNodeInfoRequest(num, CurChannel);
  EmitPainted(C_META, 'requesting node info from ' + NodeNumToId(num) + ' (name appears if it replies)');
end;

procedure DoTo(const who: string);
var
  num: LongWord;
begin
  if Trim(who) = '' then
  begin
    HaveTarget := False;
    ShowPainted(C_META, 'target cleared; messages now broadcast to channel ' + IntToStr(CurChannel));
    Exit;
  end;
  if not Client.ResolveTarget(who, num) then
  begin
    ShowPainted(C_META, 'unknown node: ' + who);
    Exit;
  end;
  Target := num;
  HaveTarget := True;
  ShowPainted(C_META, 'default target set to ' + Client.NodeLabel(num));
end;

procedure DoCh(const arg: string);
var
  n, code: Integer;
begin
  Val(Trim(arg), n, code);
  if (code <> 0) or (n < 0) or (n > 7) then
  begin
    ShowPainted(C_META, 'usage: /ch <0..7>');
    Exit;
  end;
  CurChannel := n;
  ShowPainted(C_META, 'outgoing channel set to ' + IntToStr(n));
end;

procedure Dispatch(const line: string);
var
  cmd, rest: string;
  sp, n, code: Integer;
begin
  if line = '' then Exit;
  if line[1] <> '/' then
  begin
    DoSendText(line);
    Exit;
  end;
  sp := Pos(' ', line);
  if sp = 0 then
  begin
    cmd := LowerCase(line);
    rest := '';
  end
  else
  begin
    cmd := LowerCase(Copy(line, 1, sp - 1));
    rest := Trim(Copy(line, sp + 1, Length(line)));
  end;

  case cmd of
    '/help', '/?':   CmdHelp;
    '/nodes':        CmdNodes;
    '/channels':     CmdChannels;
    '/dm':           DoDM(rest);
    '/trace':        DoTrace(rest);
    '/info':         DoInfo(rest);
    '/whois':        DoWhois(rest);
    '/to':           DoTo(rest);
    '/ch':           DoCh(rest);
    '/log':          CmdLog(rest);
    '/clear':        begin ClrScr; DrawPrompt; end;
    '/verbose':      begin Verbose := not Verbose; Show('verbose = ' + BoolToStr(Verbose, True)); end;
    '/version':      ShowPainted(C_BANNER, BannerText);
    '/confirm':      begin ConfirmSends := not ConfirmSends; Show('confirm-before-send = ' + BoolToStr(ConfirmSends, True)); end;
    '/hops':
      begin
        if Trim(rest) = '' then
          ShowPainted(C_META, Format('hop limit = %d', [DefaultHopLimit]))
        else
        begin
          Val(Trim(rest), n, code);
          if (code <> 0) or (n < 1) or (n > 7) then
            ShowPainted(C_META, 'usage: /hops <1..7>   (3 = Meshtastic default, 7 = max)')
          else
          begin
            DefaultHopLimit := n;
            ShowPainted(C_META, Format('hop limit set to %d (applies to messages sent from now on)', [n]));
          end;
        end;
      end;
    '/bell':
      begin
        BellOn := not BellOn;
        if BellOn then
        begin
          ShowPainted(C_META, 'notification sound on');
          NotifySound(False);            { sample it }
        end
        else
          ShowPainted(C_META, 'notification sound off');
      end;
    '/names':
      begin
        Client.ShowIds := not Client.ShowIds;
        if Client.ShowIds then
          ShowPainted(C_META, 'names: showing short name and id, e.g. OO11 (!458f4727)')
        else
          ShowPainted(C_META, 'names: showing short name only, e.g. OO11');
      end;
    '/quit', '/exit': Running := False;
  else
    ShowPainted(C_META, 'unknown command: ' + cmd + '   (try /help)');
  end;
end;

{ ------------------------------------------------------------------ }
{ keyboard                                                           }
{ ------------------------------------------------------------------ }

const
  HISTORY_MAX = 12;

{ Replace the visible input line with s (used by history browsing). }
procedure ReplaceInput(const s: string);
begin
  Write(#13);            { column 1 }
  ClrEol;               { wipe the old prompt + input }
  Input := s;
  CursorPos := Length(s);
  DrawPrompt;           { redraw "> " + new input, cursor at end }
end;

{ Redraw the whole input line after a text change, keeping the cursor at CursorPos. }
procedure RedrawInput;
begin
  Write(#13);
  ClrEol;
  DrawPrompt;
end;

{ Move the on-screen cursor to CursorPos without rewriting the text. }
procedure ReposCursor;
begin
  GotoXY(Length(PROMPT) + CursorPos + 1, WhereY);
end;

procedure InsertChar(ch: Char);
begin
  Insert(ch, Input, CursorPos + 1);
  Inc(CursorPos);
  RedrawInput;
end;

procedure BackspaceChar;          { delete the character before the cursor }
begin
  if CursorPos > 0 then
  begin
    Delete(Input, CursorPos, 1);
    Dec(CursorPos);
    RedrawInput;
  end;
end;

procedure DeleteChar;             { delete the character at the cursor }
begin
  if CursorPos < Length(Input) then
  begin
    Delete(Input, CursorPos + 1, 1);
    RedrawInput;
  end;
end;

procedure CursorLeft;
begin
  if CursorPos > 0 then begin Dec(CursorPos); ReposCursor; end;
end;

procedure CursorRight;
begin
  if CursorPos < Length(Input) then begin Inc(CursorPos); ReposCursor; end;
end;

procedure CursorHome;
begin
  CursorPos := 0; ReposCursor;
end;

procedure CursorEnd;
begin
  CursorPos := Length(Input); ReposCursor;
end;

{ Record a submitted line, capping at HISTORY_MAX and skipping consecutive dups. }
procedure AddHistory(const s: string);
var
  i: Integer;
begin
  if s <> '' then
  begin
    if (Length(History) = 0) or (History[High(History)] <> s) then
    begin
      SetLength(History, Length(History) + 1);
      History[High(History)] := s;
      if Length(History) > HISTORY_MAX then
      begin
        for i := 0 to High(History) - 1 do
          History[i] := History[i + 1];
        SetLength(History, HISTORY_MAX);
      end;
    end;
  end;
  HistIndex := Length(History);   { reset browsing cursor to the new line }
  Scratch := '';
end;

procedure HistoryUp;
begin
  if Length(History) = 0 then Exit;
  if HistIndex = Length(History) then Scratch := Input;  { save in-progress line }
  if HistIndex > 0 then
  begin
    Dec(HistIndex);
    ReplaceInput(History[HistIndex]);
  end;
end;

procedure HistoryDown;
begin
  if HistIndex >= Length(History) then Exit;   { already at the new line }
  Inc(HistIndex);
  if HistIndex = Length(History) then
    ReplaceInput(Scratch)                       { back to the in-progress line }
  else
    ReplaceInput(History[HistIndex]);
end;

{ Ask for confirmation before transmitting a message. Returns True to send. }
function ConfirmSend: Boolean;
var
  c: Char;
  dest: string;
begin
  if HaveTarget then dest := 'DM to ' + Client.NodeLabel(Target)
  else dest := 'channel ' + IntToStr(CurChannel);
  Write(#13); ClrEol;
  WriteColoured(Paint(C_META, 'send to ' + dest + '?  [Enter/y = send, n/Esc = cancel] '));
  Flush(Output);
  repeat
    c := ReadKey;
    if c = #0 then ReadKey;   { swallow 2nd byte of an extended key }
  until (c = 'y') or (c = 'Y') or (c = 'n') or (c = 'N') or
        (c = #13) or (c = #10) or (c = #27) or (c = #3);
  Write(#13); ClrEol;
  Result := (c = 'y') or (c = 'Y') or (c = #13) or (c = #10);
end;

procedure ProcessKey(ch: Char);
var
  line, seq: string;
  code, c2, c3: Char;
begin
  case ch of
    #0:                       { CRT extended key: 2nd byte is a scan code }
      begin
        code := ReadKey;
        case code of
          #72: HistoryUp;     { up arrow }
          #80: HistoryDown;   { down arrow }
          #75: CursorLeft;    { left arrow }
          #77: CursorRight;   { right arrow }
          #71: CursorHome;    { Home }
          #79: CursorEnd;     { End }
          #83: DeleteChar;    { Delete }
        end;
      end;
    #27:                      { raw ESC sequence (terminals CRT doesn't translate) }
      begin
        if KeyPressed then                       { ESC + more bytes = a key sequence }
        begin
          code := ReadKey;                       { '[' or 'O' }
          if (code = '[') or (code = 'O') then
          begin
            code := ReadKey;                     { final byte -- read unconditionally }
            case code of
              'A': HistoryUp;
              'B': HistoryDown;
              'C': CursorRight;
              'D': CursorLeft;
              'H': CursorHome;
              'F': CursorEnd;
              '1'..'9':
                begin
                  { extended CSI, e.g. ESC[3~ (Delete): collect digits to terminator }
                  seq := code;
                  while KeyPressed do
                  begin
                    code := ReadKey;
                    if (code >= '0') and (code <= '9') then seq := seq + code
                    else Break;                  { '~' or other terminator }
                  end;
                  if (seq = '1') or (seq = '7') then CursorHome
                  else if (seq = '4') or (seq = '8') then CursorEnd
                  else if seq = '3' then DeleteChar;
                end;
            end;
          end;
        end;
      end;
    #1:      CursorHome;       { Ctrl-A }
    #5:      CursorEnd;        { Ctrl-E }
    #3:      Running := False; { Ctrl-C }
    #13, #10:
      begin
        Writeln;
        line := Trim(Input);
        AddHistory(line);           { remember what was typed }
        Input := '';                { clear before dispatch so the prompt is empty }
        CursorPos := 0;
        if line = '' then
          DrawPrompt
        else if line[1] = '/' then
          Dispatch(line)            { a command: send straight through, no confirm }
        else if (not ConfirmSends) or ConfirmSend then
          Dispatch(line)            { a message: confirmed (or confirmation disabled) }
        else
        begin
          Input := line;            { cancelled: put it back for editing / resend }
          CursorPos := Length(line);
          ShowPainted(C_META, 'cancelled');
        end;
      end;
    #8, #127:                 { backspace }
      BackspaceChar;
  else
    { CRT hands back escape sequences it doesn't recognise with their bytes
      REVERSED. The End key (ESC[F) therefore arrives as 'F', '[', ESC. Detect
      that here and treat it as End; otherwise insert the character normally. }
    if (ch = 'F') and KeyPressed then
    begin
      c2 := ReadKey;
      if c2 = '[' then
      begin
        if KeyPressed then
        begin
          c3 := ReadKey;
          if c3 = #27 then
            CursorEnd                 { Crt-mangled End key }
          else
          begin
            InsertChar('F'); InsertChar('['); ProcessKey(c3);
          end;
        end
        else
        begin
          InsertChar('F'); InsertChar('[');
        end;
      end
      else
      begin
        InsertChar('F'); ProcessKey(c2);
      end;
    end
    else if ch >= ' ' then
      InsertChar(ch);
  end;
end;

{ ------------------------------------------------------------------ }
{ startup                                                            }
{ ------------------------------------------------------------------ }

procedure Usage;
begin
  Writeln('Usage:');
  Writeln('  tiemesh --serial <port> [--baud <rate>] [--verbose] [--no-colour] [--show-ids]');
  {$IFDEF MESH_BLE}
  Writeln('  tiemesh --ble <address> [--ble-adapter <hciN>] [--verbose] [--no-colour]');
  {$ENDIF}
  Writeln;
  Writeln('Examples:');
  Writeln('  tiemesh --serial /dev/ttyACM0');
  Writeln('  tiemesh --serial COM5 --baud 115200');
  Writeln('  tiemesh --serial /dev/ttyACM0 --no-colour');
  Writeln('  tiemesh --serial /dev/ttyACM0 --show-ids');
  Writeln('  tiemesh --serial /dev/ttyACM0 --hops 3');
  Writeln('  tiemesh --serial /dev/ttyACM0 --no-bell');
  Writeln('  tiemesh --serial /dev/ttyACM0 --bell-cmd "aplay ~/alert.wav"');
end;

function BuildTransport: ITransport;
var
  i: Integer;
  a, port, ble, baudS: string;
  {$IFDEF MESH_BLE}bleAdapter: string;{$ENDIF}
  baud, code: LongInt;
  hops: LongInt;
begin
  Result := nil;
  port := '';
  ble := '';
  {$IFDEF MESH_BLE}bleAdapter := 'hci0';{$ENDIF}
  baud := 115200;
  i := 1;
  while i <= ParamCount do
  begin
    a := ParamStr(i);
    if (a = '--serial') or (a = '-s') then begin Inc(i); if i <= ParamCount then port := ParamStr(i); end
    else if (a = '--ble') or (a = '-b') then begin Inc(i); if i <= ParamCount then ble := ParamStr(i); end
    else if (a = '--baud') then begin Inc(i); if i <= ParamCount then baudS := ParamStr(i); end
    else if (a = '--verbose') or (a = '-v') then Verbose := True
    else if (a = '--no-colour') or (a = '--no-color') then NoColour := True
    else if (a = '--show-ids') then ShowIdsFlag := True
    else if (a = '--ble-adapter') then
    begin
      Inc(i);   { consume the value in any build so it isn't taken as a port }
      {$IFDEF MESH_BLE}
      if i <= ParamCount then bleAdapter := ParamStr(i);
      {$ENDIF}
    end
    else if (a = '--no-bell') then BellOn := False
    else if (a = '--bell-cmd') then begin Inc(i); if i <= ParamCount then BellCmd := ParamStr(i); end
    else if (a = '--hops') then
    begin
      Inc(i);
      if i <= ParamCount then
      begin
        Val(ParamStr(i), hops, code);
        if (code = 0) and (hops >= 1) and (hops <= 7) then DefaultHopLimit := hops;
      end;
    end
    else if port = '' then port := a;   { bare argument = serial port }
    Inc(i);
  end;

  if baudS <> '' then
  begin
    Val(baudS, baud, code);
    if code <> 0 then baud := 115200;
  end;

  if ble <> '' then
  begin
    {$IFDEF MESH_BLE}
    Writeln('Connecting to BLE device ', ble, ' ...');
    Result := TBLETransport.Create(ble, bleAdapter);
    {$ELSE}
    Writeln('BLE support was not compiled in. Rebuild with -dMESH_BLE (Linux/BlueZ).');
    Halt(2);
    {$ENDIF}
  end
  else if port <> '' then
  begin
    Writeln('Opening serial port ', port, ' at ', baud, ' baud ...');
    Result := TSerialTransport.Create(port, baud);
  end
  else
  begin
    Usage;
    Halt(1);
  end;
end;

procedure WaitForConfig(timeoutMs: Integer);
var
  waited: Integer;
begin
  Writeln('Requesting node database from radio ...');
  Client.BeginConfig;
  waited := 0;
  while (not Client.ConfigComplete) and (waited < timeoutMs) do
  begin
    Client.Poll;
    Sleep(20);
    Inc(waited, 20);
  end;
  if not Client.ConfigComplete then
    Writeln('Warning: configuration did not complete within ',
      timeoutMs div 1000, 's; continuing anyway.');
end;

begin
  WriteColoured(Paint(C_BANNER, BannerText));
  Writeln;
  Handlers := THandlers.Create;
  try
    { Logs live in the user's home directory (~/tiemesh.log). GetUserDir
      returns the home path with a trailing separator. }
    LogPath := GetUserDir + 'tiemesh.log';
    DebugPath := GetUserDir + 'tiemesh-debug.log';
    AssignFile(LogFile, LogPath);
    try
      if FileExists(LogPath) then Append(LogFile) else Rewrite(LogFile);
      LogFileOpen := True;
    except
      LogFileOpen := False;
    end;

    try
      Trans := BuildTransport;
    except
      on E: Exception do
      begin
        Writeln('Error: ', E.Message);
        Halt(1);
      end;
    end;

    Client := TMeshClient.Create(Trans);
    Client.ShowIds := ShowIdsFlag;
    Client.OnText := @Handlers.OnText;
    Client.OnTrace := @Handlers.OnTrace;
    Client.OnDebug := @Handlers.OnDebug;
    Client.OnNode := @Handlers.OnNode;
    Client.OnConfig := @Handlers.OnConfig;
    Client.OnAck := @Handlers.OnAck;
    Client.OnTelemetry := @Handlers.OnTelemetry;
    Client.OnNodeInfo := @Handlers.OnNodeInfo;

    WaitForConfig(8000);

    Writeln;
    Writeln('Connected. Type /help for commands, /quit to exit.');
    Writeln;
    DrawPrompt;

    while Running do
    begin
      Client.Poll;
      while KeyPressed do
        ProcessKey(ReadKey);
      Sleep(15);
    end;

    Writeln;
    Writeln('Disconnecting ...');
    Client.Disconnect;
    Client.Free;
    Trans := nil;

    if LogFileOpen then CloseFile(LogFile);
    if DebugFileOpen then CloseFile(DebugFile);
  finally
    Handlers.Free;
  end;
end.
