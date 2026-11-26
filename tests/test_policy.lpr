program test_policy;
{ Driver for tests/policy.sh: the policy layer (presets, file groups, canonical methods,
  data-type detection, memory sizes).
    test_policy decode <file of -m texts> <cpus...>   one line per text and thread count
    test_policy canon <file of methods> <sizes...>     LimitAndCanonize
    test_policy stagemem <file of stages> <limits...>  CanonStageMem
    test_policy groups <file of names>                 rank, group bits and first group
    test_policy detect <file> [chunk]                  types and statistics of each chunk
    test_policy mem <strings...>                       ParseMemSize }
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, parc_presets, parc_canon, parc_filetype, parc_bytes;

var
  L: TStringList;
  i, k: Integer;
  GM: TGroupMethods;
  Line: string;
  F: TFileStream;
  Buf: TBytes;
  Chunk, Pos_, Len: Int64;
  S: TDatatypeStats;
  V: QWord;
  Bits: QWord;
  Names: TStringArray;

procedure LoadList(const Path: string);
begin
  L := TStringList.Create;
  L.LoadFromFile(Path);
end;

begin
  if ParamCount < 1 then Halt(2);
  case ParamStr(1) of
    'decode':
      begin
        LoadList(ParamStr(2));
        for i := 0 to L.Count - 1 do
          for k := 3 to ParamCount do
          begin
            GM := DecodeMethod(L[i], StrToInt(ParamStr(k)));
            Line := '[' + L[i] + '] c' + ParamStr(k) + ' =>';
            for Pos_ := 0 to High(GM) do
              Line := Line + ' {' + GM[Pos_].Group + '=' + GM[Pos_].Method + '}';
            WriteLn(Line);
          end;
      end;
    'canon':
      begin
        LoadList(ParamStr(2));
        for i := 0 to L.Count - 1 do
          for k := 3 to ParamCount do
            WriteLn('[', L[i], '] ', ParamStr(k), ' => ', LimitAndCanonize(L[i], StrToInt64(ParamStr(k))));
      end;
    'stagemem':
      begin
        LoadList(ParamStr(2));
        for i := 0 to L.Count - 1 do
          for k := 3 to ParamCount do
            WriteLn('[', L[i], '] ', ParamStr(k), ' => ', CanonStageMem(L[i], StrToInt64(ParamStr(k))));
      end;
    'groups':
      begin
        LoadList(ParamStr(2));
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
    'detect':
      begin
        F := TFileStream.Create(ParamStr(2), fmOpenRead or fmShareDenyNone);
        try
          Chunk := StrToInt64Def(ParamStr(3), 65536);
          SetLength(Buf, Chunk);
          Pos_ := 0;
          repeat
            Len := F.Read(Buf[0], Chunk);
            if Len <= 0 then Break;
            S := DatatypeStats(@Buf[0], Len);
            WriteLn(Pos_, ' ', DetectDatatype(@Buf[0], Len), ' H0=', S.H0, ' H1=', S.H1, ' let=', S.Letters,
              ' sp=', S.Spaces, ' ctl=', S.Controls, ' h3=', S.Hit3, ' h5=', S.Hit5, ' mt=', S.MatchBytes,
              ' near=', S.NearPairs);
            Inc(Pos_, Len);
          until Len < Chunk;
          if Pos_ = 0 then WriteLn('0 ', DetectDatatype(@Buf[0], 0));
        finally
          F.Free;
        end;
      end;
    'mem':
      for k := 2 to ParamCount do
        if ParseMemSize(ParamStr(k), V) then WriteLn(ParamStr(k), ' ', V)
        else WriteLn(ParamStr(k), ' bad');
  else
    Halt(2);
  end;
end.
