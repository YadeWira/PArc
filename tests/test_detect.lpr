program test_detect;
{ Cross-platform driver for tests/policy_cross.sh (pure Pascal: only the detector and the
  presets/file groups, no codecs).
    test_detect detect <file> [chunk]          type and statistics of each chunk
    test_detect decode <file of -m texts> <cpus...>
    test_detect groups <file of names> }
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, parc_presets, parc_filetype;

var
  L: TStringList;
  i, k, j: Integer;
  GM: TGroupMethods;
  Line: string;
  F: TFileStream;
  Buf: TBytes;
  Chunk, Pos_, Len: Int64;
  S: TDatatypeStats;
  Bits: QWord;
  Names: TStringArray;

begin
  if ParamCount < 2 then Halt(2);
  case ParamStr(1) of
    'detect':
      begin
        F := TFileStream.Create(ParamStr(2), fmOpenRead or fmShareDenyNone);
        try
          Chunk := StrToInt64Def(ParamStr(3), 65536);
          SetLength(Buf, Chunk + 1);
          Pos_ := 0;
          repeat
            Len := F.Read(Buf[0], Chunk);
            if Len <= 0 then Break;
            S := DatatypeStats(@Buf[0], Len);
            WriteLn(Pos_, ' ', DetectDatatype(@Buf[0], Len), ' ', S.H0, ' ', S.H1, ' ', S.Letters, ' ',
              S.Spaces, ' ', S.Controls, ' ', S.Hit3, ' ', S.Hit5, ' ', S.MatchBytes, ' ', S.NearPairs);
            Inc(Pos_, Len);
          until Len < Chunk;
        finally
          F.Free;
        end;
      end;
    'decode':
      begin
        L := TStringList.Create;
        L.LoadFromFile(ParamStr(2));
        for i := 0 to L.Count - 1 do
          for k := 3 to ParamCount do
          begin
            GM := DecodeMethod(L[i], StrToInt(ParamStr(k)));
            Line := '[' + L[i] + '] c' + ParamStr(k) + ' =>';
            for j := 0 to High(GM) do Line := Line + ' {' + GM[j].Group + '=' + GM[j].Method + '}';
            WriteLn(Line);
          end;
      end;
    'groups':
      begin
        L := TStringList.Create;
        L.LoadFromFile(ParamStr(2));
        Names := FileGroupNames;
        for i := 0 to L.Count - 1 do
        begin
          Bits := FileGroupMatches(L[i]);
          Line := '';
          for k := 0 to High(Names) do
            if Bits and (QWord(1) shl k) <> 0 then Line := Line + ' ' + Names[k];
          WriteLn(FileGroupRank(L[i]), #9, L[i], #9, Trim(Line));
        end;
      end;
  else
    Halt(2);
  end;
end.
