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
  Start: SizeInt;
{$ELSE}
  Sub: Integer;
{$ENDIF}
  Tab: PXfTab;
  Pos, RipAt: SizeInt;
  Va, V: LongWord;
  B, F, ModRM, Kind, NPfx, Map, Base, Count, S: Integer;
  O16, A16, RexW, M64, ModRMDone: Boolean;

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

  { one byte to or from the opcode stream }
  procedure Op1; inline;
  begin
{$IFDEF XF_ENC}
    Sp[XS_OP]^ := Plain[Pos];
{$ELSE}
    Plain[Pos] := Sp[XS_OP]^;
{$ENDIF}
    Inc(Sp[XS_OP]);
    Inc(Pos);
  end;

  { a 32-bit value that the stream keeps as Value + Add (mod 2^32), most significant byte first;
    Plain keeps it little endian }
  procedure XferAddr(St: Integer; Add: LongWord); inline;
  begin
{$IFDEF XF_ENC}
    StoreBE32(Sp[St], LoadLE32(@Plain[Pos]) + Add);
{$ELSE}
    StoreLE32(@Plain[Pos], LoadBE32(Sp[St]) - Add);
{$ENDIF}
    Inc(Sp[St], 4);
    Inc(Pos, 4);
  end;

  { imm16 / imm32 by operand size }
  procedure ImmZ; inline;
  begin
    if O16 then Xfer(XS_I16, 2) else Xfer(XS_I32, 4);
  end;

begin
  Result := True;
  for S := 0 to XF_NSTREAMS - 1 do Sp[S] := C.P[S];
  M64 := R.Mode = 64;
  if M64 then Tab := @XfTab64 else Tab := @XfTab32;
  Va := R.Va;
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

{$IFDEF XF_ENC}
    Start := Pos;
    if Plain[Pos] = XF_ESC then
    begin
      Sp[XS_OP][0] := XF_ESC;
      Sp[XS_OP][1] := XF_SUB_LIT;
      Inc(Sp[XS_OP], 2);
      Inc(Pos);
      Continue;
    end;
    Tail := RegLen - Pos < XF_MAXINSN;
    if Tail then
      for S := 0 to XF_NSTREAMS - 1 do Save[S] := Sp[S];
{$ELSE}
    if Sp[XS_OP]^ = XF_ESC then
    begin
      Sub := Sp[XS_OP][1];
      Inc(Sp[XS_OP], 2);
      if Sub = XF_SUB_LIT then
      begin
        Plain[Pos] := XF_ESC;
        Inc(Pos);
      end
      else if (Sub < XF_MAXINSN) and (Sub <= RegLen - Pos) then
        Xfer(XS_OP, Sub)
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
      Op1;
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
      Op1;
      B := Plain[Pos - 1];
      if B = $38 then
      begin
        Op1;
        F := XF_MODRM;
      end
      else if B = $3A then
      begin
        Op1;
        F := XF_MODRM or XI_B;
      end
      else
        F := XfTab0F[B];
    end
    else if F and XF_VEX <> 0 then
    begin
      { C4/C5 (VEX) and 62 (EVEX); in 32-bit mode only when the next byte has mod = 3,
        otherwise LES/LDS/BOUND with that byte as the ModRM. }
      Op1;
      ModRM := Plain[Pos - 1];
      if M64 or (ModRM >= $C0) then
      begin
        if B = $C5 then Map := 1
        else if B = $C4 then
        begin
          Map := ModRM and $1F;
          Op1;
        end
        else
        begin
          Map := ModRM and 7;
          Xfer(XS_OP, 2);
        end;
        Op1;
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
        Op1;
        ModRM := Plain[Pos - 1];
      end;
      if ModRM < $C0 then
      begin
        if A16 and not M64 then
        begin
          if ModRM and $C7 = $06 then Xfer(XS_D32, 2)
          else if ModRM >= $80 then Xfer(XS_D32, 2)
          else if ModRM >= $40 then Op1;
        end
        else
        begin
          Base := ModRM and 7;
          if Base = 4 then
          begin
            Op1;
            Base := Plain[Pos - 1] and 7;
          end;
          if ModRM >= $80 then Xfer(XS_D32, 4)
          else if ModRM >= $40 then Op1
          else if Base = 5 then
          begin
            if M64 and (ModRM and 7 = 5) then
            begin
              RipAt := Pos;          // RIP-relative: converted once the length is known
              Inc(Pos, 4);
            end
            else
              XferAddr(XS_ADDR, 0);
          end;
        end;
      end;
    end;

    Kind := F and XF_IMM;
    case Kind of
      XI_NONE: ;
      XI_B: Op1;
      XI_W: Xfer(XS_I16, 2);
      XI_Z: ImmZ;
      XI_V: if RexW then Xfer(XS_I32, 8) else ImmZ;
      XI_ENTER: begin Xfer(XS_I16, 2); Op1; end;
      XI_FAR: begin ImmZ; Xfer(XS_I16, 2); end;
      XI_MOFFS: if M64 then
                begin
                  if A16 then XferAddr(XS_ADDR, 0) else Xfer(XS_I32, 8);
                end
                else
                begin
                  if A16 then Xfer(XS_I16, 2) else XferAddr(XS_ADDR, 0);
                end;
      XI_G3B: if ModRM and $38 < $10 then Op1;
      XI_G3Z: if ModRM and $38 < $10 then ImmZ;
      XI_REL8: Op1;
      XI_CALL:
        if O16 and not M64 then Xfer(XS_I16, 2)
        else XferAddr(XS_CALL, Va + LongWord(Pos + 4));
      XI_JMP:
        if O16 and not M64 then Xfer(XS_I16, 2)
        else XferAddr(XS_JMP, Va + LongWord(Pos + 4));
    end;

    if RipAt >= 0 then
    begin
      V := Va + LongWord(Pos);
{$IFDEF XF_ENC}
      StoreBE32(Sp[XS_ADDR], LoadLE32(@Plain[RipAt]) + V);
{$ELSE}
      StoreLE32(@Plain[RipAt], LoadBE32(Sp[XS_ADDR]) - V);
{$ENDIF}
      Inc(Sp[XS_ADDR], 4);
    end;

{$IFDEF XF_ENC}
    if Tail and (Pos > RegLen) then
    begin
      { the instruction does not fit: the rest of the region goes as raw bytes }
      for S := 0 to XF_NSTREAMS - 1 do Sp[S] := Save[S];
      Pos := Start;
      Sp[XS_OP][0] := XF_ESC;
      Sp[XS_OP][1] := RegLen - Pos;
      Inc(Sp[XS_OP], 2);
      Xfer(XS_OP, RegLen - Pos);
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
