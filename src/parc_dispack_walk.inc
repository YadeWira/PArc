{ parc_dispack_walk.inc: the instruction walker of the x86 filter (parc_dispack.pas), included
  twice: with XF_ENC defined it splits Plain into the streams (encoder), without it it rebuilds
  Plain from the streams (decoder). Both sides make every decision from bytes of Plain that are
  already known (the encoder reads them, the decoder has just written them), so the parse is the
  same in both directions. XF_NAME is the function name.

  Returns False only in the decoder, for a damaged stream. }

function XF_NAME(var C: TXfCtx; Plain: PByte; RegLen: SizeInt; const R: TXfRegion): Boolean;
var
  Sp: array[0..XF_NSTREAMS - 1] of PByte;
{$IFDEF XF_ENC}
  Save: array[0..XF_NSTREAMS - 1] of PByte;
  Tail: Boolean;
  Lo, Hi, Ib: LongWord;
{$ELSE}
  Sub: Integer;
{$ENDIF}
  Tab: PXfTab;
  Pos, Start, RipAt: SizeInt;
  Va: LongWord;
  B, F, ModRM, Md, Rm, Base, Kind, NPfx, Map: Integer;
  O16, A16, RexW, M64, ModRMDone: Boolean;
  V: LongWord;
  N, I, Count: Integer;
  S: Integer;

  { moves Cnt bytes between Plain[Pos] and stream St }
  procedure Xfer(St, Cnt: Integer); inline;
  begin
{$IFDEF XF_ENC}
    Move(Plain[Pos], Sp[St]^, Cnt);
{$ELSE}
    Move(Sp[St]^, Plain[Pos], Cnt);
{$ENDIF}
    Inc(Sp[St], Cnt);
    Inc(Pos, Cnt);
  end;

  procedure Xfer1(St: Integer); inline;
  begin
{$IFDEF XF_ENC}
    Sp[St]^ := Plain[Pos];
{$ELSE}
    Plain[Pos] := Sp[St]^;
{$ENDIF}
    Inc(Sp[St]);
    Inc(Pos);
  end;

  { a 32-bit value that the stream keeps as Value + Add (mod 2^32), most significant byte first;
    Plain keeps it little endian }
  procedure XferAddr(St: Integer; Add: LongWord); inline;
  var
    X: LongWord;
  begin
{$IFDEF XF_ENC}
    X := LoadLE32(@Plain[Pos]) + Add;
    StoreBE32(Sp[St], X);
{$ELSE}
    X := LoadBE32(Sp[St]) - Add;
    StoreLE32(@Plain[Pos], X);
{$ENDIF}
    Inc(Sp[St], 4);
    Inc(Pos, 4);
  end;

  { call target through the move-to-front table: an index in OP, or XfMtfSize + the address }
  procedure XferCall(Add: LongWord);
  var
    X: LongWord;
    r, k: Integer;
  begin
{$IFDEF XF_ENC}
    X := LoadLE32(@Plain[Pos]) + Add;
    r := 0;
    while (r < XfMtfSize) and (C.Mtf[r] <> X) do Inc(r);
    Sp[XfMap[XS_OP]]^ := r;
    Inc(Sp[XfMap[XS_OP]]);
    if r = XfMtfSize then
    begin
      StoreBE32(Sp[XfMap[XS_CALL]], X);
      Inc(Sp[XfMap[XS_CALL]], 4);
      r := XfMtfSize - 1;
    end;
{$ELSE}
    r := Sp[XfMap[XS_OP]]^;
    Inc(Sp[XfMap[XS_OP]]);
    if r >= XfMtfSize then
    begin
      X := LoadBE32(Sp[XfMap[XS_CALL]]);
      Inc(Sp[XfMap[XS_CALL]], 4);
      r := XfMtfSize - 1;
    end
    else
      X := C.Mtf[r];
    StoreLE32(@Plain[Pos], X - Add);
{$ENDIF}
    for k := r downto 1 do C.Mtf[k] := C.Mtf[k - 1];
    C.Mtf[0] := X;
    Inc(Pos, 4);
  end;

  procedure XferImm(Size: Integer); inline;
  begin
    case Size of
      1: Xfer1(XfMap[XS_I8]);
      2: Xfer(XfMap[XS_I16], 2);
      4: Xfer(XfMap[XS_I32], 4);
      8: Xfer(XfMap[XS_I32], 8);
    end;
  end;

begin
  Result := True;
  for S := 0 to XF_NSTREAMS - 1 do Sp[S] := C.P[S];
  M64 := R.Mode = 64;
  if M64 then Tab := @XfTab64 else Tab := @XfTab32;
  Va := R.Va;
{$IFDEF XF_ENC}
  Lo := R.Va;
  Hi := R.Va + LongWord(RegLen);
  Ib := R.ImageBase;
{$ENDIF}
  Pos := 0;
  Count := 0;
  while Pos < RegLen do
  begin
    Inc(Count);
    if Count and 63 = 0 then
    begin
      for S := 0 to XF_NSTREAMS - 1 do C.P[S] := Sp[S];
{$IFDEF XF_ENC}
      XfEnsure(C);
{$ELSE}
      if not XfCheck(C) then Exit(False);
{$ENDIF}
      for S := 0 to XF_NSTREAMS - 1 do Sp[S] := C.P[S];
    end;
    Start := Pos;

{$IFDEF XF_ENC}
    { jump tables: runs of 32-bit addresses (VA) or image-relative addresses (RVA) that point
      inside this region }
    if R.Tables and (RegLen - Pos >= 8) then
    begin
      V := LoadLE32(@Plain[Pos]);
      N := 0;
      if XfJtVa > 0 then
        while (N < XF_JT_MAX) and (RegLen - Pos >= 4 * (N + 1)) and
              (LoadLE32(@Plain[Pos + 4 * N]) - Lo < Hi - Lo) do Inc(N);
      if N >= XfJtVa then
      begin
        Sp[XfMap[XS_OP]]^ := XF_ESC;
        Sp[XfMap[XS_OP]][1] := XF_SUB_VA + N - 2;
        Inc(Sp[XfMap[XS_OP]], 2);
        for I := 1 to N do XferAddr(XfMap[XS_JT], 0);
        Continue;
      end;
      N := 0;
      if XfJtRva > 0 then
        while (N < XF_JT_MAX) and (RegLen - Pos >= 4 * (N + 1)) and
              (LoadLE32(@Plain[Pos + 4 * N]) + Ib - Lo < Hi - Lo) do Inc(N);
      if N >= XfJtRva then
      begin
        Sp[XfMap[XS_OP]]^ := XF_ESC;
        Sp[XfMap[XS_OP]][1] := XF_SUB_RVA + N - 2;
        Inc(Sp[XfMap[XS_OP]], 2);
        for I := 1 to N do XferAddr(XfMap[XS_JT], Ib);
        Continue;
      end;
    end;
    if Plain[Pos] = XF_ESC then
    begin
      Sp[XfMap[XS_OP]]^ := XF_ESC;
      Sp[XfMap[XS_OP]][1] := XF_SUB_LIT;
      Inc(Sp[XfMap[XS_OP]], 2);
      Inc(Pos);
      Continue;
    end;
    Tail := RegLen - Pos < XF_MAXINSN;
    if Tail then
      for S := 0 to XF_NSTREAMS - 1 do Save[S] := Sp[S];
{$ELSE}
    if Sp[XfMap[XS_OP]]^ = XF_ESC then
    begin
      Sub := Sp[XfMap[XS_OP]][1];
      Inc(Sp[XfMap[XS_OP]], 2);
      if Sub = XF_SUB_LIT then
      begin
        Plain[Pos] := XF_ESC;
        Inc(Pos);
      end
      else if Sub < XF_MAXINSN then
      begin
        if Sub > RegLen - Pos then Exit(False);
        Xfer(XfMap[XS_OP], Sub);
      end
      else if Sub >= XF_SUB_VA then
      begin
        if Sub >= XF_SUB_RVA then
        begin
          N := Sub - XF_SUB_RVA + 2;
          V := R.ImageBase;
        end
        else
        begin
          N := Sub - XF_SUB_VA + 2;
          V := 0;
        end;
        if 4 * N > RegLen - Pos then Exit(False);
        for I := 1 to N do XferAddr(XfMap[XS_JT], V);
      end
      else
        Exit(False);
      Continue;
    end;
{$ENDIF}

    { prefixes (at most XF_MAXPFX: one more is taken as the opcode) }
    NPfx := 0;
    O16 := False;
    A16 := False;
    RexW := False;
    repeat
      Xfer1(XfMap[XS_OP]);
      B := Plain[Pos - 1];
      F := Tab^[B];
      if (F and XF_PFX = 0) or (NPfx >= XF_MAXPFX) then Break;
      Inc(NPfx);
      if B = $66 then O16 := True
      else if B = $67 then A16 := True;
      RexW := M64 and (B and $F8 = $48);
    until False;

    ModRMDone := False;
    ModRM := 0;
    if F and XF_0F <> 0 then
    begin
      Xfer1(XfMap[XS_OP]);
      B := Plain[Pos - 1];
      if B = $38 then
      begin
        Xfer1(XfMap[XS_OP]);
        F := XF_MODRM;
      end
      else if B = $3A then
      begin
        Xfer1(XfMap[XS_OP]);
        F := XF_MODRM or XI_B;
      end
      else
        F := XfTab0F[B];
    end
    else if F and XF_VEX <> 0 then
    begin
      { C4/C5 (VEX) and 62 (EVEX); in 32-bit mode only when the next byte has mod = 3,
        otherwise LES/LDS/BOUND with that byte as the ModRM. The byte always goes to the
        opcode stream so that the decoder can tell. }
      Xfer1(XfMap[XS_OP]);
      ModRM := Plain[Pos - 1];
      if M64 or (ModRM >= $C0) then
      begin
        if B = $C5 then Map := 1
        else if B = $C4 then
        begin
          Map := ModRM and $1F;
          Xfer1(XfMap[XS_OP]);
        end
        else
        begin
          Map := ModRM and 7;
          Xfer(XfMap[XS_OP], 2);
        end;
        Xfer1(XfMap[XS_OP]);
        B := Plain[Pos - 1];
        case Map of
          1: begin
               F := XfTab0F[B];
               if F and XF_IMM <> XI_B then F := F and XF_MODRM;
               if B <> $77 then F := F or XF_MODRM;
             end;
          3: F := XF_MODRM or XI_B;
        else
          F := XF_MODRM;
        end;
      end
      else
      begin
        ModRMDone := True;
        F := XF_MODRM;
      end;
    end;

    RipAt := -1;
    if F and XF_MODRM <> 0 then
    begin
      if not ModRMDone then
      begin
        Xfer1(XfMap[XS_MODRM]);
        ModRM := Plain[Pos - 1];
      end;
      Md := ModRM shr 6;
      Rm := ModRM and 7;
      if Md <> 3 then
      begin
        if A16 and not M64 then
        begin
          if (Md = 0) and (Rm = 6) then Xfer(XfMap[XS_D32], 2)
          else if Md = 1 then Xfer1(XfMap[XS_D8])
          else if Md = 2 then Xfer(XfMap[XS_D32], 2);
        end
        else
        begin
          Base := Rm;
          if Rm = 4 then
          begin
            Xfer1(XfMap[XS_SIB]);
            Base := Plain[Pos - 1] and 7;
          end;
          if Md = 1 then Xfer1(XfMap[XS_D8])
          else if Md = 2 then Xfer(XfMap[XS_D32], 4)
          else if Base = 5 then
          begin
            if M64 and (Rm = 5) then
            begin
              RipAt := Pos;          // RIP-relative: converted once the length is known
              Inc(Pos, 4);
            end
            else
              XferAddr(XfMap[XS_ADDR], 0);
          end;
        end;
      end;
    end;

    Kind := F and XF_IMM;
    case Kind of
      XI_NONE: ;
      XI_B: Xfer1(XfMap[XS_I8]);
      XI_W: Xfer(XfMap[XS_I16], 2);
      XI_Z: if O16 then Xfer(XfMap[XS_I16], 2) else Xfer(XfMap[XS_I32], 4);
      XI_V: if RexW then Xfer(XfMap[XS_I32], 8) else if O16 then Xfer(XfMap[XS_I16], 2) else Xfer(XfMap[XS_I32], 4);
      XI_ENTER: begin Xfer(XfMap[XS_I16], 2); Xfer1(XfMap[XS_I8]); end;
      XI_FAR: begin
                if O16 then Xfer(XfMap[XS_I16], 2) else Xfer(XfMap[XS_I32], 4);
                Xfer(XfMap[XS_I16], 2);
              end;
      XI_MOFFS: if M64 then
                begin
                  if A16 then XferAddr(XfMap[XS_ADDR], 0) else Xfer(XfMap[XS_I32], 8);
                end
                else
                begin
                  if A16 then Xfer(XfMap[XS_I16], 2) else XferAddr(XfMap[XS_ADDR], 0);
                end;
      XI_G3B: if (ModRM shr 3) and 7 < 2 then Xfer1(XfMap[XS_I8]);
      XI_G3Z: if (ModRM shr 3) and 7 < 2 then
                if O16 then Xfer(XfMap[XS_I16], 2) else Xfer(XfMap[XS_I32], 4);
      XI_REL8: Xfer1(XfMap[XS_J8]);
      XI_CALL, XI_JMP:
        if O16 and not M64 then Xfer(XfMap[XS_I16], 2)
        else if Kind = XI_CALL then
        begin
          if XfMtfSize > 0 then XferCall(Va + LongWord(Pos + 4))
          else XferAddr(XfMap[XS_CALL], Va + LongWord(Pos + 4));
        end
        else XferAddr(XfMap[XS_JMP], Va + LongWord(Pos + 4));
    end;

    if RipAt >= 0 then
    begin
      V := Va + LongWord(Pos);
{$IFDEF XF_ENC}
      StoreBE32(Sp[XfMap[XS_ADDR]], LoadLE32(@Plain[RipAt]) + V);
{$ELSE}
      StoreLE32(@Plain[RipAt], LoadBE32(Sp[XfMap[XS_ADDR]]) - V);
{$ENDIF}
      Inc(Sp[XfMap[XS_ADDR]], 4);
    end;

{$IFDEF XF_ENC}
    if Tail and (Pos > RegLen) then
    begin
      { the instruction does not fit: the rest of the region goes as raw bytes }
      for S := 0 to XF_NSTREAMS - 1 do Sp[S] := Save[S];
      Pos := Start;
      Sp[XfMap[XS_OP]]^ := XF_ESC;
      Sp[XfMap[XS_OP]][1] := RegLen - Pos;
      Inc(Sp[XfMap[XS_OP]], 2);
      Xfer(XfMap[XS_OP], RegLen - Pos);
    end;
{$ELSE}
    if Pos > RegLen then Exit(False);
{$ENDIF}
  end;
  for S := 0 to XF_NSTREAMS - 1 do C.P[S] := Sp[S];
{$IFNDEF XF_ENC}
  Result := XfCheck(C);
{$ENDIF}
end;
