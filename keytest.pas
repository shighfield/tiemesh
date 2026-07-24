program keytest;
{ Shows exactly what FPC's Crt ReadKey returns for each key press, so we can see
  how End / Home / arrows are delivered on your terminal.
  Build:  fpc keytest.pas
  Run:    ./keytest      (press keys; press capital Q to quit) }
{$mode objfpc}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF} Crt;
var
  c: Char;
begin
  Writeln('Press keys to see their byte values. Try: End, Home, Left, Right, Delete.');
  Writeln('Each ReadKey result prints on its own line. Press capital Q to quit.');
  Writeln;
  repeat
    c := ReadKey;
    Write('  byte = ', Ord(c):3);
    if (Ord(c) >= 32) and (Ord(c) < 127) then Write('   char = ''', c, '''');
    if Ord(c) = 27 then Write('   (ESC)');
    if Ord(c) = 0 then Write('   (extended: next byte is a scan code)');
    Writeln;
  until c = 'Q';
  Writeln('done.');
end.
