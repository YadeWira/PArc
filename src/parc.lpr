{ PArc — archivador .parc en Pascal.
  Listado, test, extracción, creación y actualización de archivos .parc. }
program parc;

{$mode objfpc}{$H+}
{ win32: "large address aware" (como FreeArc): en Windows de 64 bits el proceso tiene 4 GB de
  direcciones en vez de 2, y los diccionarios grandes (lzma:1gb) se achican menos. }
{$IFDEF WIN32}{$SETPEFLAGS $20}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  Classes, SysUtils, Types, DateUtils, parc_os, parc_bytes, parc_methods, parc_archive, parc_extract, parc_writer, parc_encoders, parc_presets, parc_recovery, parc_progress, parc_solid, parc_strmap, parc_volume, parc_console, parc_parallel, parc_crypt, parc_select, parc_canon;

const
  PARC_VERSION = '0.0.5';
  // Método por defecto: el mismo que FreeArc (-m4)
  DEFAULT_METHOD = '4';
  // Directorio y footer: lo mismo que usa FreeArc
  DIR_METHOD = 'lzma:1mb:normal:bt4:32';
  EXIT_NOMEM = 7;      // algún bloque pide más memoria que -ld

{ Los errores de TFileStream vienen de FPC en inglés ("Unable to open file \"x\":
  No such file or directory"). Se traducen los casos habituales y se conserva el nombre. }
function FileErrorText(const Msg: string; Opening: Boolean): string;
var
  p, q: Integer;
  Name, Reason: string;
begin
  Result := Msg;
  p := Pos('"', Msg);
  if p = 0 then Exit;
  q := p + 1;
  while (q <= Length(Msg)) and (Msg[q] <> '"') do Inc(q);
  if q > Length(Msg) then Exit;
  Name := Copy(Msg, p + 1, q - p - 1);
  Reason := Copy(Msg, q + 1, MaxInt);
  if Copy(Reason, 1, 2) = ': ' then Delete(Reason, 1, 2);
  if Pos('No such file', Reason) > 0 then Reason := 'does not exist'
  else if Pos('Permission denied', Reason) > 0 then Reason := 'permission denied'
  else if Pos('Is a directory', Reason) > 0 then Reason := 'is a directory'
  else if Pos('File exists', Reason) > 0 then Reason := 'already exists';
  if Reason = '' then
  begin
    if Opening then Result := 'could not open "' + Name + '"'
    else Result := 'could not create "' + Name + '"';
  end
  else if Opening then Result := 'could not open "' + Name + '": ' + Reason
  else Result := 'could not create "' + Name + '": ' + Reason;
end;

procedure PrintBanner;
begin
  OutLn('PArc ' + PARC_VERSION + '  ·  .parc archiver');
end;

procedure ShortHelp;
begin
  PrintBanner;
  OutLn('');
  OutLn('Usage:');
  OutLn('  parc <command> <archive> [files...] [options]');
  OutLn('  parc help [command]');
  OutLn('');
  OutLn('Commands:');
  OutLn('  l    list contents              x    extract with paths');
  OutLn('  lb   list internal blocks       e    extract without paths');
  OutLn('  t    test archive               a    add / update archive');
  OutLn('  u    update newer files         f    freshen existing files');
  OutLn('  d    delete files               r    repair with recovery record');
  OutLn('  v    verbose listing            lt   technical listing');
  OutLn('  m    move files into archive    mf   move files only (keep folders)');
  OutLn('  ch   rewrite with new options   j    join archives into the first');
  OutLn('  c    set the archive comment    cw   write the comment to a file');
  OutLn('  k    lock the archive           rr<spec> add a recovery record');
  OutLn('  create   new archive (replaces an existing one)');
  OutLn('');
  OutLn('Common options:');
  OutLn('  -m<level>   -m0..-m9, -mx, -mxx (default -m4)');
  OutLn('  -s...       solid blocks: -s-, -se, -s<N>f, -s<N>m');
  OutLn('  -dp<dir>    extraction destination');
  OutLn('  -o+ / -o-   overwrite / skip existing files');
  OutLn('  -p<pass>    encrypt or read an encrypted archive');
  OutLn('  -x<pat> / -n<pat>   exclude / include only matching files (@listfile too)');
  OutLn('  -t          test the archive after a/u/f/d');
  OutLn('  -mt<N>      threads (like PARC_THREADS)');
  OutLn('  --no-progress   hide the progress line');
  OutLn('  --verbose       list each file tested or extracted');
  OutLn('');
  OutLn('Examples:');
  OutLn('  parc a backup.parc ~/Documents -m6');
  OutLn('  parc t backup.parc');
  OutLn('  parc x backup.parc -dp~/restore -o+');
  OutLn('');
  OutLn('Run "parc help" for all options, or "parc help <command>".');
end;

procedure LongHelp;
begin
  PrintBanner;
  OutLn('');
  OutLn('Usage:');
  OutLn('  parc <command> <archive> [files/patterns...] [options]');
  OutLn('  parc help [command]');
  OutLn('  parc --version');
  OutLn('');
  OutLn('Commands:');
  OutLn('  l    list archive contents');
  OutLn('  lb   list internal blocks (technical)');
  OutLn('  t    test archive integrity (decompress and check CRCs)');
  OutLn('  x    extract, keeping stored paths');
  OutLn('  e    extract, without stored paths');
  OutLn('  a    add files, replacing existing ones; create archive if missing');
  OutLn('  u    add or replace only files newer than the archived copy');
  OutLn('  f    freshen only files already in the archive');
  OutLn('  d    delete files matching the given names/patterns');
  OutLn('  r    repair with the recovery record; writes fixed.<name>');
  OutLn('  v    verbose listing (ns times, attributes, packed size, ratio, block, method)');
  OutLn('  lt   technical listing: blocks (like lb) and each file''s block and offset');
  OutLn('  create   like a, but always starts a new archive (replaces an existing one)');
  OutLn('  m / mf   like a, then delete the archived files from disk (m: also empty folders)');
  OutLn('  ch   rewrite the archive with the options given (-m, -p/-hp/-p-, -rr, -k, -z)');
  OutLn('  rr<spec> add or replace the recovery record (rr, rr5%, rr10...): ch -rr<spec>');
  OutLn('  c    set the comment (-z<file>, -z for stdin, --archive-comment=<text>)');
  OutLn('  cw   write the comment to a file: parc cw <archive> <file|->');
  OutLn('  j    join: parc j <archive> <other.parc>... appends their files (blocks copied)');
  OutLn('  k    lock the archive: no command can modify it afterwards');
  OutLn('');
  OutLn('General options:');
  OutLn('  -dp<dir>        extraction destination (attached: -dpout)');
  OutLn('  -o+ / -o-       overwrite / skip existing files (default: skip)');
  OutLn('  -y              answer yes to all queries (overwrite, unless -o-)');
  OutLn('  -snld           allow links pointing outside the destination');
  OutLn('  -so             x/e: write file contents to stdout');
  OutLn('  -si[name]       a: add stdin as that name (default: stdin)');
  OutLn('  -r              patterns also match files in subdirectories');
  OutLn('  -kb             x/e: keep broken files (CRC error, incomplete)');
  OutLn('  -k              lock the archive being written (like command k)');
  OutLn('  -d / -df        a/u/f: delete archived files from disk (like m / mf)');
  OutLn('  -z[file]        archive comment from a file, or stdin with plain -z');
  OutLn('  --archive-comment=<text>  archive comment');
  OutLn('  -w<dir>         directory for temporary files');
  OutLn('  -mt<N>          thread budget (overrides PARC_THREADS; -mt0 = default)');
  OutLn('  --recompress    rebuild intact blocks instead of copying them');
  OutLn('  --print-config  show built-in method presets and file groups');
  OutLn('  --no-progress   hide the progress line');
  OutLn('  --verbose       list each file tested or extracted');
  OutLn('');
  OutLn('File selection (a/u/f and l/t/x/e/d):');
  OutLn('  -x<pattern>     exclude matching files (repeatable; -x@listfile)');
  OutLn('  -n<pattern>     include only matching files (repeatable; -n@listfile)');
  OutLn('  @listfile       names/patterns from a file, one per line (# comments)');
  OutLn('  -sm<size> / -sl<size>   larger / smaller than size (k, m, g)');
  OutLn('  -ta<time> / -tb<time>   modified after / before YYYYMMDD[hhmmss]');
  OutLn('  -tn<per> / -to<per>     newer / older than a period: 10d, 2h30m, 1w');
  OutLn('  --dirs / -ed    include / exclude directory entries');
  OutLn('  -ep / -ep1      store names without paths / without the base dir;');
  OutLn('                  x -ep extracts without paths');
  OutLn('  -ap<dir>        base directory inside the archive');
  OutLn('');
  OutLn('Updating (a, u, f, d):');
  OutLn('  -t / -tp        test after the operation / test the archive before it');
  OutLn('  --sync          a/u: delete archived files missing on disk');
  OutLn('  -ag[FMT]        append date/time to the archive name (YYYYMMDDhhmmss)');
  OutLn('  --nodates       do not store file times');
  OutLn('  -tk / -tl       keep the archive time / set it to the newest file');
  OutLn('');
  OutLn('Compression:');
  OutLn('  -m<method>      preset -m0..-m9 (default -m4), -mx (max, fast decode),');
  OutLn('                  -mxx (CM max, slow decode), or a method: -mlzma, -mcm');
  OutLn('  -s...           solid blocks: -s- non-solid, -se by extension,');
  OutLn('                  -s<N>f N files, -s<N>m blocks of at least N bytes');
  OutLn('                  default: solid, split only where a method needs it');
  OutLn('  -rr[spec]       recovery record: -rr, -rr5%, -rr10, -rr-');
  OutLn('  -mc-<alg>       drop an algorithm from the chains: -mc-orep, -mc-exe,');
  OutLn('                  -mcd- (delta), -mc-$text (group); repeatable');
  OutLn('  -lc<size>       memory limit per compressor (shrinks dictionaries)');
  OutLn('  -ld<size>       x/e/t: refuse blocks needing more memory (exit 7)');
  OutLn('');
  OutLn('Encryption:');
  OutLn('  -p<password>    encrypt data; on read, password for the archive');
  OutLn('  -hp[password]   also encrypt the directory/footer');
  OutLn('  -ae=<alg>       chacha (XChaCha20-Poly1305, default) or aes (AES-256-GCM);');
  OutLn('                  key derivation Argon2id t3 m64m p4, change with :t<n>:m<n>m:p<n>');
  OutLn('  -kf<file>       key file: alone, or together with -p (both needed)');
  OutLn('  -op<password>   old password, only for reading (ch changing or removing it)');
  OutLn('  -p- / -hp-      ch: remove all encryption / only the headers encryption');
  OutLn('');
  OutLn('Volumes and streams:');
  OutLn('  -v<size>        volumes: -v100m, -v4g, -v700000k');
  OutLn('  "-" as archive  read from stdin or write to stdout');
  OutLn('');
  OutLn('Examples:');
  OutLn('  parc a backup.parc ~/Documents -m6');
  OutLn('  parc u backup.parc ~/Documents');
  OutLn('  parc l backup.parc "*.txt"');
  OutLn('  parc t backup.parc');
  OutLn('  parc x backup.parc -dp~/restore -o+');
  OutLn('  parc a backup.parc ~/src -psecret -rr5%');
  OutLn('');
  OutLn('Exit codes: 0 ok · 1 usage · 2 corrupt · 3 unsupported · 4 I/O · 5 password ·');
  OutLn('            6 warnings · 7 memory limit (-ld) · 130 cancelled.');
  OutLn('Full manual: docs/USO.md');
end;

function CommandHelp(const Name: string): Boolean;
var C: string;
begin
  C := LowerCase(Name);
  Result := True;
  if (Copy(C, 1, 2) = 'rr') then
  begin
    OutLn('parc rr<spec> <archive>');
    OutLn('  Add or replace the recovery record (same spec as -rr: rr, rr5%, rr10, rr4k...);');
    OutLn('  data blocks are copied. Same as ch -rr<spec>; ch -rr- removes it.');
    Exit;
  end;
  case C of
    'l':
      begin
        OutLn('parc l <archive> [patterns...] [options]');
        OutLn('  List archive contents. Patterns filter the listing.');
        OutLn('  Selection: -n, -x, @listfile, -sm/-sl, -ta/-tb/-tn/-to, -ap<dir>, --dirs/-ed');
      end;
    'lb':
      begin
        OutLn('parc lb <archive>');
        OutLn('  List internal control and data blocks with their codecs.');
      end;
    't':
      begin
        OutLn('parc t <archive> [patterns...] [options]');
        OutLn('  Decompress and verify CRCs without writing files.');
        OutLn('  Common: -p<pass>, -kf<file>, -ld<size>, selection options as in l');
      end;
    'x':
      begin
        OutLn('parc x <archive> [patterns...] [options]');
        OutLn('  Extract keeping stored paths.');
        OutLn('  Common: -dp<dir>, -o+, -o-, -y, -snld, -p<pass>, -kf<file>, -so, -kb, -ld<size>');
        OutLn('  -ep extracts without paths; -ap<dir> extracts only that subtree, relative to it');
        OutLn('  Selection: -n, -x, @listfile, -sm/-sl, -ta/-tb/-tn/-to, --dirs/-ed');
      end;
    'e':
      begin
        OutLn('parc e <archive> [patterns...] [options]');
        OutLn('  Extract without stored paths (flat names).');
        OutLn('  Common: -dp<dir>, -o+, -o-, -y, -snld, -p<pass>, -kf<file>, -so, -kb, -ld<size>');
        OutLn('  Selection: -n, -x, @listfile, -sm/-sl, -ta/-tb/-tn/-to, -ap<dir>');
      end;
    'a', 'u', 'f':
      begin
        OutLn('parc ' + C + ' <archive> <files...> [options]');
        OutLn('  a: add/replace · u: only newer · f: only files already archived');
        OutLn('  Common: -m<level>, -s..., -p<pass>, -kf<file>, -rr..., -x<pattern>, -n<pattern>, -r');
        OutLn('  Paths: -ep (no paths), -ep1 (no base dir), -ap<dir> (prefix in the archive)');
        OutLn('  Filters: -sm/-sl, -ta/-tb/-tn/-to, --dirs/-ed, @listfile');
        OutLn('  Also: -t, -tp, --sync (a/u), -ag[FMT], --nodates, -tk, -tl, -w<dir>, -mt<N>,');
        OutLn('        -mc-<alg>, -lc<size>');
      end;
    'd':
      begin
        OutLn('parc d <archive> <names/patterns...> [options]');
        OutLn('  Delete matching entries from the archive.');
        OutLn('  Names/patterns, -n, -x, -sm/-sl, -ta/-tb/-tn/-to and -ap<dir> select what is');
        OutLn('  deleted (at least one is required); -t / -tp test after / before.');
      end;
    'r':
      begin
        OutLn('parc r <archive>');
        OutLn('  Repair using the recovery record; writes fixed.<name>.');
      end;
    'v':
      begin
        OutLn('parc v <archive> [patterns...] [options]');
        OutLn('  Verbose listing: time with nanoseconds (UTC), Unix mode or Windows attributes,');
        OutLn('  size, share of the packed block, ratio, CRC, block number and its method.');
        OutLn('  Selection options as in l.');
      end;
    'lt':
      begin
        OutLn('parc lt <archive>');
        OutLn('  Technical listing: control and data blocks (as lb) plus, for every entry, its');
        OutLn('  block, offset inside the uncompressed block, size, CRC, mtime in ns and mode.');
      end;
    'create':
      begin
        OutLn('parc create <archive> <files...> [options]');
        OutLn('  Like a, but the archive is always created from scratch: an existing one is');
        OutLn('  replaced (only after the new one is complete).');
      end;
    'm', 'mf':
      begin
        OutLn('parc ' + C + ' <archive> <files...> [options]');
        OutLn('  Like a, then delete from disk what was archived: m deletes the files and then');
        OutLn('  the folders it added if they are empty; mf deletes files only. Nothing is');
        OutLn('  deleted unless the archive was written (and, with -t, tested) without errors;');
        OutLn('  a file that changed after being read is kept. Links are deleted, never their');
        OutLn('  targets. Options -d / -df do the same with a, u, f.');
      end;
    'ch':
      begin
        OutLn('parc ch <archive> [options]');
        OutLn('  Rewrite the archive with the options given; untouched blocks are copied.');
        OutLn('  -m<method> (implies --recompress), --recompress, -rr<spec> / -rr-, -k, -z,');
        OutLn('  --archive-comment=, -v<size>. Encryption: -p<new> re-encrypts everything with a');
        OutLn('  new password (headers too if they were encrypted), -hp<new> encrypts the headers,');
        OutLn('  -p- removes all encryption, -hp- only the headers one. The current password goes');
        OutLn('  in -op<old> (or is prompted); a -p that already opens the data changes nothing.');
      end;
    'c':
      begin
        OutLn('parc c <archive> -z<file> | -z | --archive-comment=<text>');
        OutLn('  Set or replace the archive comment (empty text removes it). Same as ch -z.');
      end;
    'cw':
      begin
        OutLn('parc cw <archive> <file|->');
        OutLn('  Write the archive comment to a file, or to stdout with "-".');
      end;
    'j':
      begin
        OutLn('parc j <archive> <other.parc>... [options]');
        OutLn('  Join: add the files of the other archives to the first. Their blocks are copied');
        OutLn('  as they are (encrypted blocks stay encrypted with their own password). A name');
        OutLn('  present in several archives: the last one wins (like a); blocks that lose files');
        OutLn('  are repacked with their method. -m implies --recompress.');
      end;
    'k':
      begin
        OutLn('parc k <archive>');
        OutLn('  Lock the archive: a, u, f, d, m, ch, c, rr, j and k refuse to modify it');
        OutLn('  afterwards (exit code 1); l, v, t, x, e and r still work. Same as ch -k.');
      end;
  else
    Result := False;
  end;
end;

function IsCommand(const C: string): Boolean;
begin
  Result := (C = 'l') or (C = 'lb') or (C = 't') or (C = 'x') or (C = 'e') or
            (C = 'a') or (C = 'u') or (C = 'f') or (C = 'd') or (C = 'r') or
            (C = 'c') or (C = 'cw') or (C = 'ch') or (C = 'create') or (C = 'j') or
            (C = 'm') or (C = 'mf') or (C = 'v') or (C = 'lt') or (C = 'k') or
            (Copy(C, 1, 2) = 'rr');
end;

procedure Usage;
begin
  LongHelp;
end;

procedure PrintBlock(const B: TArcBlock);
begin
  OutLn(Format('  %-10s pos=%-12d orig=%-12d comp=%-12d %s',
    [BlockTypeName(B.BlockType), B.Pos, B.OrigSize, B.CompSize, B.Method]));
end;

procedure CmdBlocks(A: TArchive);
var
  i: Integer;
begin
  OutLn(Format('Archive: %s (%d bytes), SFX=%d, locked=%s, recovery="%s"',
    [A.FileName, A.ArcSize, A.SFXSize, BoolToStr(A.Locked, 'yes', 'no'), A.Recovery]));
  OutLn('Control blocks:');
  for i := 0 to High(A.ControlBlocks) do PrintBlock(A.ControlBlocks[i]);
  PrintBlock(A.Footer);
  OutLn('Data blocks:');
  for i := 0 to High(A.DataBlocks) do
  begin
    PrintBlock(A.DataBlocks[i]);
    OutLn(Format('             %d file(s) from #%d', [A.DataBlocks[i].FileCount, A.DataBlocks[i].FirstFile]));
  end;
end;

{ lt: el listado técnico: los bloques (como lb) y, por archivo, su bloque, su posición dentro
  del bloque descomprimido, tamaño, CRC y los campos propios de .parc. }
procedure CmdTechList(A: TArchive);
var
  i: Integer;
  F: string;
begin
  CmdBlocks(A);
  if A.Comment <> '' then OutLn('Comment: ' + A.Comment);
  OutLn('Files:');
  OutLn('  #      block  offset        size          CRC       mtime (ns since 1970)  mode/attr  name');
  for i := 0 to High(A.Files) do
    with A.Files[i] do
    begin
      if IsDir then F := 'dir' else if IsLink then F := 'link' else F := IntToStr(DataBlock);
      OutLn(Format('  %-6d %-6s %-13d %-13d %.8x  %-21s  %-9s  %s%s',
        [i, F, Offset, Size, Crc, BoolToStr(HasMTimeNs, IntToStr(MTimeNs), IntToStr(Time) + '000000000'),
         BoolToStr(HasUnixMode, '0' + OctStr(UnixMode and $FFF, 4), BoolToStr(HasWinAttr, '$' + IntToHex(WinAttr, 4), '-')),
         Name, BoolToStr(IsLink, ' -> ' + LinkTarget, '')]));
    end;
end;

{ r: como "arc r": busca sectores dañados con el registro de recuperación y, si todos se
  pueden reconstruir, escribe fixed.<nombre> (el original nunca se toca). }
function CmdRepair(const ArcName: string): Integer;
var
  Res: TRecoveryResult;
  Dest: string;
  i: Integer;
  L: string;
begin
  if not RecoveryRepair(ArcName, Res, Dest) then
  begin
    ErrLn('ERROR: ' + ArcName + ' has no recovery record (create one with -rr)');
    Exit(1);
  end;
  OutLn(Format('Recovery record %s: %d sector(s) of %d bytes',
    [Res.Info.Version, Res.Info.RecSectors, Res.Info.SectorSize]));
  if Length(Res.BadSectors) = 0 then
  begin
    OutLn('No damaged sectors.');
    Exit(0);
  end;
  L := '';
  for i := 0 to High(Res.BadSectors) do L := L + ' ' + IntToStr(Res.BadSectors[i]);
  OutLn(Format('Damaged sectors (%d):%s', [Length(Res.BadSectors), L]));
  if Length(Res.Unrecoverable) > 0 then
  begin
    L := '';
    for i := 0 to High(Res.Unrecoverable) do L := L + ' ' + IntToStr(Res.Unrecoverable[i]);
    ErrLn(Format('ERROR: %d unrecoverable sector(s) (too many damaged sectors in the same group for the record to repair):%s',
      [Length(Res.Unrecoverable), L]));
    Exit(2);
  end;
  OutLn(Format('Repaired %d sector(s) -> %s', [Length(Res.Repaired), Dest]));
  Result := 0;
end;

function TimingText(T0, T1: QWord; Bytes: Int64): string;
begin
  if (Bytes <= 0) or (T1 <= T0) then Exit('');
  Result := Format('   time: %.2f s   speed: %.1f MB/s',
    [(T1 - T0) / 1000.0, Bytes / ((T1 - T0) / 1000.0) / 1048576.0]);
end;

function CmdExtract(A: TArchive; const Cmd: string; const Opt0: TExtractOptions): Integer;
var
  Opt: TExtractOptions;
  St: TExtractStats;
  T0, T1: QWord;
  Cpu0: Int64;
  i: Integer;
  PackedBytes: Int64;
  L: string;
begin
  Opt := Opt0;
  Opt.TestOnly := Cmd = 't';
  Opt.FlatNames := (Cmd = 'e') or Opt0.FlatNames;   // -ep: x sin rutas
  if Opt.TestOnly then L := 'testing' else L := 'extracting from';
  OutLn(Paint('PArc ' + PARC_VERSION, '1') + Paint(' · ', '2') + L + ' archive: ' + A.FileName);
  T0 := GetTickCount64;
  Cpu0 := ProcessCpuMs;
  St := ExtractArchive(A, Opt, @LogLine);
  T1 := GetTickCount64;
  PackedBytes := 0;
  for i := 0 to High(A.DataBlocks) do Inc(PackedBytes, A.DataBlocks[i].CompSize);
  if Opt.TestOnly then L := 'Tested ' else L := 'Extracted ';
  L := L + Count(St.Files, 'file');
  if not Opt.TestOnly and (St.Dirs > 0) then L := L + ' and ' + Count(St.Dirs, 'folder');
  L := L + ', ' + Num(St.Bytes) + ' bytes';
  if (St.Bytes > 0) and (PackedBytes > 0) then L := L + Format(' · ratio %.2f%%', [100.0 * PackedBytes / St.Bytes]);
  if St.Skipped > 0 then L := L + ' · skipped ' + Num(St.Skipped);
  OutLn(L);
  if Opt.TestOnly then L := 'Testing' else L := 'Extraction';
  PrintTimes(L, T0, T1, Cpu0, ProcessCpuMs, St.Bytes);
  PrintResult(St.Errors);
  if St.MemLimited then
  begin
    ErrLn('Some blocks were not decompressed because of the -ld memory limit (raise it or use -ld-).');
    Result := EXIT_NOMEM;
  end
  else if St.Unsupported then Result := 3
  else if St.Errors > 0 then Result := 2
  else Result := 0;
end;

{ Orden en que Windows (NTFS, y wine) devuelve un directorio: sin distinguir mayúsculas,
  comparando en MAYÚSCULAS ('_' va después de las letras); si empatan, por bytes. }
function FileSizeOf(const Name: string): Int64;
var
  M: TFileMeta;
begin
  if GetFileMeta(Name, M) then Result := M.Size else Result := 0;
end;

{ Clave para comparar nombres del archivo con los del disco (en Windows sin mayúsculas). }
function NameKeyOf(const Name: string): string;
begin
  {$IFDEF WINDOWS}Result := LowerCase(Name);{$ELSE}Result := Name;{$ENDIF}
end;

{ ¿Path es el archivo que se está escribiendo (ArcPath), uno de sus volúmenes (ArcPath.001...)
  o un temporal (ArcPath.tmp, ArcPath.tmp.001...)? }
function IsOwnArchiveFile(const Path, ArcPath: string): Boolean;
var
  Rest: string;
  i: Integer;
begin
  if Path = ArcPath then Exit(True);
  if Copy(Path, 1, Length(ArcPath) + 1) <> ArcPath + '.' then Exit(False);
  Rest := Copy(Path, Length(ArcPath) + 2, MaxInt);
  if Rest = 'tmp' then Exit(True);
  if Copy(Rest, 1, 4) = 'tmp.' then Delete(Rest, 1, 4);
  Result := Length(Rest) >= 3;
  for i := 1 to Length(Rest) do
    if not (Rest[i] in ['0'..'9']) then Exit(False);
end;

function CompareEntryNames(List: TStringList; A, B: Integer): Integer;
var
  i, n: Integer;
  ca, cb: Byte;
  SA, SB: string;
begin
  SA := List[A]; SB := List[B];
  n := Length(SA);
  if Length(SB) < n then n := Length(SB);
  for i := 1 to n do
  begin
    ca := Ord(SA[i]); cb := Ord(SB[i]);
    if ca in [Ord('a')..Ord('z')] then Dec(ca, 32);
    if cb in [Ord('a')..Ord('z')] then Dec(cb, 32);
    if ca <> cb then Exit(Integer(ca) - Integer(cb));
  end;
  Result := Length(SA) - Length(SB);
  if Result = 0 then Result := CompareStr(SA, SB);
end;

{ Junta las entradas a agregar: cada argumento es un archivo, un directorio (recursivo) o una
  máscara con * y ? en el último componente ("src/*.pas"), como en FreeArc: la expande el propio
  parc porque cmd.exe no lo hace. Sin -r la máscara mira solo ese directorio (y los directorios
  que coinciden entran enteros); con -r busca también en todos los subdirectorios.
  Los nombres guardados son los del argumento, saneados (sin raíz ni ".."), salvo:
    -ep   solo el nombre del archivo, sin directorios (y sin entradas de directorio; un nombre
          repetido se avisa y se saltea);
    -ep1  relativos al argumento: sin el directorio base dado en la línea de comandos;
    -ap   con <dir>/ delante.
  Los filtros (-x, -n, -sm/-sl, -ta/-tb/-tn/-to, --dirs/-ed) miran el nombre sin -ap.
  Scopes: lo que cubre cada argumento en el archivo (para --sync). }
type
  TCollectScope = record
    Prefix: string;     // nombre guardado del argumento ('' = todo, con -ep1 o -ep)
    Mask: string;       // máscara del último componente ('' = no es máscara)
    Exact: Boolean;     // un archivo suelto
    Recursive: Boolean;
  end;
  TCollectScopes = array of TCollectScope;

var
  Unreadable: TStringList = nil;   // archivos que no se pudieron abrir (se saltean con aviso)
  UnreadableStored: TStringList = nil;   //   y su nombre en el archivo (--sync no los borra)

procedure CollectEntries(const Paths: TStringList; const Exclude: string; const SO: TSelectOptions;
  Recursive: Boolean; EpMode: Integer; var Entries: TWriteEntryArray; var Scopes: TCollectScopes);
var
  Cnt: Integer;          // Entradas usadas (Entries crece al doble)
  ExclBase, TempFull: string;
  Flat: TStringList;     // -ep: nombres ya usados

  procedure AddEntry(const Disk, Stored0: string; const Meta: TFileMeta);
  var
    n: Integer;
    H: THandle;
    B, Stored, Full: string;
  begin
    Stored := Stored0;
    if Stored = '' then Exit;
    // ExpandFileName (getcwd) solo si el nombre puede ser el del archivo que se escribe
    B := ExtractFileName(Disk);
    if (B = '') or (B = '.') or (B = '..') or (Copy(B, 1, Length(ExclBase)) = ExclBase) then
    begin
      Full := ExpandFileName(Disk);
      if IsOwnArchiveFile(Full, Exclude) then Exit;   // ni el archivo que se escribe ni sus volúmenes
      if (TempFull <> '') and (Copy(Full, 1, Length(TempFull)) = TempFull) then Exit;   // ni su temporal (-w)
    end;
    if EpMode = 0 then
    begin
      if Meta.IsDir then Exit;
      Stored := Copy(Stored, LastDelimiter('/', Stored) + 1, MaxInt);
    end;
    if not Selected(SO, Stored, Meta.IsDir, Meta.Size, Meta.MTimeNs, False) then Exit;
    if EpMode = 0 then
    begin
      if Flat.IndexOf(NameKeyOf(Stored)) >= 0 then
      begin
        ErrLn('Warning: duplicate name ' + Stored + ' with -ep (' + Disk + ' skipped)');
        Exit;
      end;
      Flat.Add(NameKeyOf(Stored));
    end;
    if SO.ArcPath <> '' then Stored := SO.ArcPath + '/' + Stored;
    // Uno ilegible (sin permiso, o bloqueado por otro programa en Windows) no aborta todo el
    // trabajo: se avisa y se saltea; al actualizar queda la versión que ya estaba en el archivo.
    // (FreeArc tenía el bug opuesto: el archivo desaparecía del archivo comprimido.)
    if not Meta.IsDir and not Meta.IsLink then
    begin
      {$IFDEF UNIX}
      // Open+close sin el flock de FileOpen (mismo criterio: ¿se puede abrir?)
      H := FpOpen(PChar(FsPath(Disk)), O_RDONLY);
      if H >= 0 then FpClose(H) else H := THandle(-1);
      {$ELSE}
      H := FileOpen(FsPath(Disk), fmOpenRead or fmShareDenyNone);
      {$ENDIF}
      if H = THandle(-1) then
      begin
        ErrLn('Warning: cannot read ' + Disk + ' (skipped)');
        if Unreadable = nil then Unreadable := TStringList.Create;
        Unreadable.Add(Disk);
        if UnreadableStored = nil then UnreadableStored := TStringList.Create;
        UnreadableStored.Add(Stored);
        Exit;
      end;
      {$IFNDEF UNIX}FileClose(H);{$ENDIF}
    end;
    n := Cnt;
    if n >= Length(Entries) then SetLength(Entries, 2 * n + 64);
    Inc(Cnt);
    Entries[n].DiskPath := Disk;
    Entries[n].StoredName := Stored;
    Entries[n].Meta := Meta;
  end;

  { Como findFiles_FileInfo de FreeArc: primero todas las entradas del directorio (en el orden
    de Windows: sin distinguir mayúsculas), después cada subdirectorio, en ese mismo orden. }
  procedure Walk(const Disk, Stored: string);
  var
    SR: TSearchRec;
    Meta: TFileMeta;
    Names: TStringList;
    Recurse: array of Boolean;
    ChildDisk, ChildStored: string;
    i: Integer;
    {$IFDEF UNIX}
    Dp: PDir;
    De: PDirent;
    Nm: string;
    St: Stat;
    {$ENDIF}
  begin
    Names := TStringList.Create;
    try
      {$IFDEF UNIX}
      // Readdir sin el stat por entrada que hace FindNext
      Dp := FpOpenDir(FsPath(Disk));
      if Dp = nil then
      begin
        ErrLn('Warning: cannot read directory ' + Disk);
        Exit;
      end;
      try
        repeat
          De := FpReadDir(Dp^);
          if De = nil then Break;
          Nm := PChar(@De^.d_name[0]);
          if (Nm <> '.') and (Nm <> '..') then Names.Add(Nm);
        until False;
      finally
        FpCloseDir(Dp^);
      end;
      {$ELSE}
      // FsPath: sin el prefijo \\?\ de Windows, un directorio de ruta larga "no existe" y todo lo
      // que tiene adentro se perdía en silencio
      if FindFirst(IncludeTrailingPathDelimiter(FsPath(Disk)) + '*', faAnyFile, SR) <> 0 then
      begin
        ErrLn('Warning: cannot read directory ' + Disk);
        Exit;
      end;
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          Names.Add(SR.Name);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
      {$ENDIF}
      Names.CustomSort(@CompareEntryNames);
      SetLength(Recurse, Names.Count);
      for i := 0 to Names.Count - 1 do
      begin
        Recurse[i] := False;
        ChildDisk := IncludeTrailingPathDelimiter(Disk) + Names[i];
        if Stored <> '' then ChildStored := Stored + '/' + Names[i] else ChildStored := Names[i];
        // Un enlace (symlink, o junction de Windows) se guarda como enlace y no se recorre:
        // así no hay ciclos ni se archiva dos veces lo mismo
        {$IFDEF UNIX}
        // un solo lstat: si no es enlace, es lo mismo que daría stat
        if (FpLStat(FsPath(ChildDisk), St) = 0) and not FpS_ISLNK(St.st_mode) then
        begin
          Meta := Default(TFileMeta);
          Meta.IsDir := FpS_ISDIR(St.st_mode);
          if not Meta.IsDir then Meta.Size := St.st_size;
          Meta.MTimeNs := Int64(St.st_mtime) * 1000000000 + {$IFDEF DARWIN}St.st_mtimensec{$ELSE}St.st_mtime_nsec{$ENDIF};
          Meta.HasUnixMode := True;
          Meta.UnixMode := St.st_mode;
        end
        else
        {$ENDIF}
        if not GetLinkMeta(ChildDisk, Meta) and not GetFileMeta(ChildDisk, Meta) then
        begin
          ErrLn('Warning: cannot read ' + ChildDisk);
          Continue;
        end;
        AddEntry(ChildDisk, ChildStored, Meta);
        Recurse[i] := Meta.IsDir;
      end;
      for i := 0 to Names.Count - 1 do
        if Recurse[i] then
        begin
          ChildDisk := IncludeTrailingPathDelimiter(Disk) + Names[i];
          if Stored <> '' then ChildStored := Stored + '/' + Names[i] else ChildStored := Names[i];
          Walk(ChildDisk, ChildStored);
        end;
    finally
      Names.Free;
    end;
  end;

  function HasWild(const S: string): Boolean;
  begin
    Result := (Pos('*', S) > 0) or (Pos('?', S) > 0);
  end;

  { Las entradas de Dir que coinciden con Mask; con Recursive, también las de sus subdirectorios.
    StoredDir: cómo se guarda Dir ('' o terminado en '/'). Devuelve cuántas coincidieron. }
  function Expand(const Dir, StoredDir, Mask: string): Integer;
  var
    SR: TSearchRec;
    Meta: TFileMeta;
    Names: TStringList;
    Child: string;
    i: Integer;
  begin
    Result := 0;
    Names := TStringList.Create;
    try
      if Dir = '' then Child := '.' else Child := Dir;
      if FindFirst(IncludeTrailingPathDelimiter(FsPath(Child)) + '*', faAnyFile {$IFDEF UNIX}or faSymLink{$ENDIF}, SR) = 0 then
        try
          repeat
            if (SR.Name <> '.') and (SR.Name <> '..') then Names.Add(SR.Name);
          until FindNext(SR) <> 0;
        finally
          FindClose(SR);
        end;
      Names.CustomSort(@CompareEntryNames);
      for i := 0 to Names.Count - 1 do
      begin
        Child := Dir + Names[i];
        if not GetLinkMeta(Child, Meta) and not GetFileMeta(Child, Meta) then Continue;
        if MatchWild(Names[i], Mask) then
        begin
          Inc(Result);
          AddEntry(Child, StoredDir + Names[i], Meta);
          if Meta.IsDir and not Meta.IsLink then Walk(Child, StoredDir + Names[i]);
        end
        else if Recursive and Meta.IsDir and not Meta.IsLink then
          Inc(Result, Expand(IncludeTrailingPathDelimiter(Child), StoredDir + Names[i] + '/', Mask));
      end;
    finally
      Names.Free;
    end;
  end;

  procedure AddScope(const Prefix, Mask: string; Exact: Boolean);
  var
    n: Integer;
  begin
    n := Length(Scopes);
    SetLength(Scopes, n + 1);
    Scopes[n].Prefix := Prefix;
    Scopes[n].Mask := Mask;
    Scopes[n].Exact := Exact;
    Scopes[n].Recursive := Recursive;
    if EpMode = 0 then
    begin
      // -ep: los nombres pierden el directorio; el argumento cubre todo
      Scopes[n].Prefix := '';
      Scopes[n].Mask := '';
      Scopes[n].Exact := False;
    end;
    if SO.ArcPath <> '' then
      if Scopes[n].Prefix = '' then Scopes[n].Prefix := SO.ArcPath
      else Scopes[n].Prefix := SO.ArcPath + '/' + Scopes[n].Prefix;
  end;

var
  i, Cut: Integer;
  Meta: TFileMeta;
  Stored, Dir, Mask, SD: string;
begin
  Cnt := Length(Entries);
  ExclBase := ExtractFileName(Exclude);
  TempFull := '';
  if WorkDir <> '' then TempFull := ExpandFileName(TempArchiveName(Exclude));
  Flat := TStringList.Create;
  Flat.Sorted := True;
  try
  for i := 0 to Paths.Count - 1 do
  begin
    if HasWild(Paths[i]) then
    begin
      Cut := LastDelimiter('/' {$IFDEF WINDOWS}+ '\:'{$ENDIF}, Paths[i]);
      Dir := Copy(Paths[i], 1, Cut);
      Mask := Copy(Paths[i], Cut + 1, MaxInt);
      if HasWild(Dir) then
        raise EFOpenError.CreateFmt('wildcards are only allowed in the last component: %s', [Paths[i]]);
      SD := SanitizePath(Dir);
      if (SD <> '') and (EpMode <> 1) then SD := SD + '/' else SD := '';
      AddScope(Copy(SD, 1, Length(SD) - 1), Mask, False);
      if Expand(Dir, SD, Mask) = 0 then ErrLn('Warning: no files match ' + Paths[i]);
      Continue;
    end;
    if not GetFileMeta(Paths[i], Meta) then
      raise EFOpenError.CreateFmt('does not exist: %s', [Paths[i]]);
    Stored := SanitizePath(Paths[i]);
    // -ep1: sin el directorio base del argumento (un directorio aporta su contenido; un
    // archivo, su nombre)
    if EpMode = 1 then
      if Meta.IsDir then Stored := '' else Stored := Copy(Stored, LastDelimiter('/', Stored) + 1, MaxInt);
    AddScope(Stored, '', not Meta.IsDir);
    if Stored <> '' then AddEntry(Paths[i], Stored, Meta);   // "." o "/" no se guardan a sí mismos
    if Meta.IsDir then Walk(ExcludeTrailingPathDelimiter(Paths[i]), Stored);
  end;
  finally
    SetLength(Entries, Cnt);
    Flat.Free;
  end;
end;

{ ¿Name (del archivo) está dentro de lo que cubre algún argumento? (--sync) }
function InScopes(const Name: string; const Scopes: TCollectScopes): Boolean;
var
  i: Integer;
  Rest, P: string;
  Parts: TStringArray;
begin
  for i := 0 to High(Scopes) do
    with Scopes[i] do
    begin
      if Exact then
      begin
        if NameKeyOf(Name) = NameKeyOf(Prefix) then Exit(True);
        Continue;
      end;
      if Prefix = '' then Rest := Name
      else if NameKeyOf(Copy(Name, 1, Length(Prefix) + 1)) = NameKeyOf(Prefix + '/') then
        Rest := Copy(Name, Length(Prefix) + 2, MaxInt)
      else if (Mask = '') and (NameKeyOf(Name) = NameKeyOf(Prefix)) then Exit(True)
      else Continue;
      if Mask = '' then Exit(True);
      Parts := Rest.Split(['/']);
      if Length(Parts) = 0 then Continue;
      if not Recursive then
      begin
        if MatchWild(Parts[0], Mask) then Exit(True);
      end
      else
        for P in Parts do
          if MatchWild(P, Mask) then Exit(True);
    end;
  Result := False;
end;

type
  TModifyOptions = record
    Method, Fmt: string;
    MethodGiven: Boolean;    // -m explícito (con d, FreeArc recompila todo: --recompress)
    Recompress: Boolean;     // --recompress: rehacer todos los bloques viejos
    Solid: TSolidLimits;     // -s...: límites de los bloques sólidos (ParseSolidSpec)
    SolidGiven: Boolean;     // -s explícito (no aplicar el tamaño de bloque automático)
    Sel: TSelectOptions;     // -x, -n, -sm/-sl, -ta/-tb/-tn/-to, --dirs/-ed, -ap
    EpMode: Integer;         // -ep: 0 sin rutas, 1 sin el directorio base; -1 = rutas completas
    Sync: Boolean;           // --sync: borrar del archivo lo que ya no está en el disco
    NoDates: Boolean;        // --nodates: no guardar las fechas de los archivos
    KeepTime: Boolean;       // -tk: el archivo conserva su fecha de antes
    TimeToLast: Boolean;     // -tl: la fecha del archivo es la del más nuevo de adentro
    McOps: TStringList;      // -mc: "grupos|algoritmo" a quitar de los métodos
    Recursive: Boolean;      // -r: las máscaras buscan también en los subdirectorios
    StdinName: string;       // -si[nombre]: un archivo más, leído de stdin, con ese nombre
    StdinFile: string;       //   el temporal donde se volcó
    ShownName: string;       // el nombre que se muestra ('' = el del archivo; "-": salida estándar)
    Recovery: string;        // -rr...: '--' si no se dio la opción
    Encryption: string;      // -ae= / --encryption=
    VolumeSize: Int64;       // -v<tamaño>: volúmenes (solo .parc); 0 = como estaba
    DataPassword, HeadersPassword: RawByteString;   // '' = sin cifrar
    Comment: RawByteString;  // -z / --archive-comment / c: el comentario nuevo
    CommentGiven: Boolean;
    Lock: Boolean;           // -k / k: el archivo queda bloqueado
    NoDataPwd, NoHeadPwd: Boolean;   // ch -p- (quitar todo el cifrado) / -hp- (el de los encabezados)
    ForceNew: Boolean;       // create: empezar de cero aunque exista
    MoveMode: Integer;       // m / -d: 1 (archivos y directorios); mf / -df: 2 (solo archivos)
  end;

var
  { m/mf/-d/-df: lo que salió del disco y quedó en el archivo (se borra después de escribirlo
    y, con -t, de probarlo). }
  MovedEntries: TWriteEntryArray = nil;
  { j: los otros archivos (quedan abiertos hasta escribir el resultado). }
  JoinArcs: array of TArchive = nil;

{ j: los archivos de A y de JoinArcs, en ese orden. Un nombre repetido lo gana el último que lo
  trae (como a: lo que se junta reemplaza). Los bloques que quedan enteros se copian tal cual
  (cifrados o no); los que pierden archivos se reempaquetan con su método (y, si estaban
  cifrados, se vuelven a cifrar con la contraseña principal). }
procedure PlanJoin(A: TArchive; Recompress: Boolean; var Entries: TWriteEntryArray;
  var Groups: TSolidGroupArray; out Added, Replaced: Integer);
var
  Arcs: array of TArchive;
  Win: TStringList;
  k, f, b, n, g, idx, total: Integer;
  Keep: array of array of Boolean;
  EIdx: array of array of Integer;
  Files: array of Integer;
  E: TWriteEntry;
begin
  SetLength(Arcs, 1 + Length(JoinArcs));
  Arcs[0] := A;
  for k := 0 to High(JoinArcs) do Arcs[k + 1] := JoinArcs[k];
  Added := 0; Replaced := 0;
  // El dueño de cada nombre: el último archivo que lo trae
  Win := TStringList.Create;
  try
    Win.Sorted := True;
    Win.Duplicates := dupIgnore;
    SetLength(Keep, Length(Arcs));
    SetLength(EIdx, Length(Arcs));
    for k := High(Arcs) downto 0 do
    begin
      SetLength(Keep[k], Length(Arcs[k].Files));
      SetLength(EIdx[k], Length(Arcs[k].Files));
      for f := 0 to High(Arcs[k].Files) do
      begin
        idx := Win.IndexOf(NameKeyOf(Arcs[k].Files[f].Name));
        Keep[k][f] := (idx < 0) or (PtrInt(Win.Objects[idx]) = k);
        if idx < 0 then Win.AddObject(NameKeyOf(Arcs[k].Files[f].Name), TObject(PtrInt(k)))
        else if (PtrInt(Win.Objects[idx]) <> k) and not Arcs[k].Files[f].IsDir then Inc(Replaced);
        EIdx[k][f] := -1;
      end;
    end;
  finally
    Win.Free;
  end;
  // Entradas, en el orden de cada archivo
  n := 0;
  SetLength(Entries, 0);
  for k := 0 to High(Arcs) do
    for f := 0 to High(Arcs[k].Files) do
      if Keep[k][f] then
      begin
        E := Default(TWriteEntry);
        E.StoredName := Arcs[k].Files[f].Name;
        E.Meta := MetaFromArchive(Arcs[k].Files[f]);
        E.SrcArc := Arcs[k];
        E.SrcIndex := f;
        if n >= Length(Entries) then SetLength(Entries, 2 * n + 64);
        Entries[n] := E;
        EIdx[k][f] := n;
        Inc(n);
        if (k > 0) and not E.Meta.IsDir and not E.Meta.IsLink then Inc(Added);
      end;
  SetLength(Entries, n);
  Dec(Added, Replaced);
  if Added < 0 then Added := 0;
  // Bloques: enteros se copian; con huecos (o --recompress / -m) se reempaquetan
  for k := 0 to High(Arcs) do
    for b := 0 to High(Arcs[k].DataBlocks) do
    begin
      Files := nil;
      total := 0;
      for f := Arcs[k].DataBlocks[b].FirstFile to Arcs[k].DataBlocks[b].FirstFile + Arcs[k].DataBlocks[b].FileCount - 1 do
      begin
        if Arcs[k].Files[f].IsDir or Arcs[k].Files[f].IsLink then Continue;
        Inc(total);
        if Keep[k][f] then
        begin
          SetLength(Files, Length(Files) + 1);
          Files[High(Files)] := EIdx[k][f];
        end;
      end;
      if Length(Files) = 0 then Continue;
      g := Length(Groups);
      SetLength(Groups, g + 1);
      Groups[g] := Default(TSolidGroup);
      Groups[g].Files := Files;
      if (Length(Files) = total) and not Recompress then
      begin
        Groups[g].CopyFrom := Arcs[k];
        Groups[g].CopyBlock := b;
        Groups[g].Method := Arcs[k].DataBlocks[b].Method;
      end
      else
        Groups[g].Method := WithoutCipher(Arcs[k].DataBlocks[b].Method);
    end;
end;


{ Como ArcRecover.hs: sin -rr se conserva lo que tenía el archivo; -rr/-rr+ usa eso o el
  recomendado por tamaño (4%/2%/1%); -rr- ninguno; -rr0.1% y -rr0.01% solo CRCs. }
function ResolveRecovery(const Opt, Old: string; ArcSize: Int64): string;
var
  Recommended: string;
begin
  if ArcSize < 300000 then Recommended := '4%'
  else if ArcSize < 2000000 then Recommended := '2%'
  else Recommended := '1%';
  case Opt of
    '-':        Result := '';
    '--':       Result := Old;
    '', '+':    if Old <> '' then Result := Old else Result := Recommended;
    '0.1%':     Result := '0*4kb';     // lo que guarda arc.exe 0.67.1 (el fuente dice 0*4096)
    '0.01%':    Result := '0*64kb';    // ídem (el fuente dice 0*65536)
  else
    Result := Opt;
  end;
end;

{ Bloques sólidos: sin -s, como FreeArc (sin tope de tamaño; solo los cortes de dict/bwt/
  lzp y de tta/mm). Antes había un tope automático (64 MB en -m1..-m3, 32 MB en -m4..-mx)
  para repartir bloques entre hilos, pero hoy 4x4, LZMA multihilo y el presupuesto global ya
  usan los hilos dentro de un bloque, y partir cortaba las repeticiones entre archivos: set
  document -m6 43,8 -> 36,6 MB (FreeArc 36,6), exe -m6..-m9 -1,9 %, -m1 -0,9..-15 %. }
function EffectiveSolid(const MO: TModifyOptions): TSolidLimits;
begin
  Result := MO.Solid;
end;

{ Nombre de una etapa ("lzma:64mb:max" -> "lzma"; dispack070 = dispack). }
function McStageName(const Stage: string): string;
begin
  Result := LowerCase(Copy(Stage, 1, Pos(':', Stage + ':') - 1));
  if Result = 'dispack070' then Result := 'dispack';
end;

{ La cadena sin las etapas Algo (vacía: storing). }
function RemoveStages(const Method, Algo: string): string;
var
  St: string;
begin
  Result := '';
  for St in Method.Split(['+']) do
    if McStageName(St) <> Algo then
    begin
      if Result <> '' then Result := Result + '+';
      Result := Result + St;
    end;
  if Result = '' then Result := 'storing';
end;

{ -mc (como Cmdline.hs, implementación propia). Cada operación es "grupos|cosa", con grupos
  separados por comas ('' = todos):
  - cosa "$grupo": se quita el método especial de ese grupo (sus archivos usan el principal);
  - cosa algoritmo: se quitan los grupos especiales cuya cadena termina en él y la etapa de
    todas las demás cadenas (una cadena que queda vacía es storing). }
procedure ApplyMcOps(var GM: TGroupMethods; Ops: TStrings);
var
  o, i, n: Integer;
  Groups, What: string;
  Last: TStringArray;

  function Applies(const G: string): Boolean;
  var
    X: string;
  begin
    if Groups = '' then Exit(True);
    for X in Groups.Split([',']) do
      if (X = G) or ((X = '$default') and (G = '')) then Exit(True);
    Result := False;
  end;

begin
  if (Ops = nil) or (Ops.Count = 0) then Exit;
  for o := 0 to Ops.Count - 1 do
  begin
    Groups := Copy(Ops[o], 1, Pos('|', Ops[o]) - 1);
    What := Copy(Ops[o], Pos('|', Ops[o]) + 1, MaxInt);
    n := 0;
    for i := 0 to High(GM) do
    begin
      if (What <> '') and (What[1] = '$') then
      begin
        if (GM[i].Group = What) and (GM[i].Group <> '') then Continue;
      end
      else if Applies(GM[i].Group) then
      begin
        Last := GM[i].Method.Split(['+']);
        if (GM[i].Group <> '') and (Length(Last) > 0) and (McStageName(Last[High(Last)]) = What) then Continue;
        GM[i].Method := RemoveStages(GM[i].Method, What);
      end;
      GM[n] := GM[i];
      Inc(n);
    end;
    SetLength(GM, n);
  end;
end;

{ Lo mismo sobre el método ya elegido de un bloque (solo quitar etapas: el grupo ya no cambia). }
function McMethod(const Method: string; Ops: TStrings): string;
var
  o: Integer;
  What: string;
begin
  Result := Method;
  if Ops = nil then Exit;
  for o := 0 to Ops.Count - 1 do
  begin
    What := Copy(Ops[o], Pos('|', Ops[o]) + 1, MaxInt);
    if (What <> '') and (What[1] <> '$') and (Copy(Ops[o], 1, Pos('|', Ops[o]) - 1) = '') then
      Result := RemoveStages(Result, What);
  end;
end;

{ Adds the planned blocks of Files (Idx[i] = entry of Files[i]) to Groups. }
procedure AddPlanned(const Blocks: TPlanBlocks; const Idx: array of Integer;
  const MO: TModifyOptions; var Groups: TSolidGroupArray);
var
  i, g, k: Integer;
begin
  for i := 0 to High(Blocks) do
  begin
    g := Length(Groups);
    SetLength(Groups, g + 1);
    Groups[g] := Default(TSolidGroup);
    Groups[g].Method := McMethod(Blocks[i].Method, MO.McOps);
    SetLength(Groups[g].Files, Length(Blocks[i].Files));
    for k := 0 to High(Blocks[i].Files) do Groups[g].Files[k] := Idx[Blocks[i].Files[k]];
  end;
end;

{ Solid blocks for entries (parc_solid: order, kind by name and content, cuts). Hints[i] <> ''
  is the method of the block an old file comes from: if a method of the list has the same
  stages, the file keeps that kind. }
procedure GroupEntries(const Entries: TWriteEntryArray; const Idx: array of Integer;
  const Hints: array of string; const MO: TModifyOptions; var Groups: TSolidGroupArray);
var
  GM: TGroupMethods;
  Files: array of TPlanFile;
  i: Integer;
begin
  if Length(Idx) = 0 then Exit;
  GM := DecodeMethod(MO.Method, BudgetThreads);   // las alternativas "(a|b)" según los hilos efectivos, como -mtN
  ApplyMcOps(GM, MO.McOps);
  SetLength(Files, Length(Idx));
  for i := 0 to High(Idx) do
  begin
    Files[i] := Default(TPlanFile);
    Files[i].Name := Entries[Idx[i]].StoredName;
    if Entries[Idx[i]].SrcArc = nil then Files[i].DiskPath := Entries[Idx[i]].DiskPath;
    Files[i].Size := Entries[Idx[i]].Meta.Size;
    if i <= High(Hints) then Files[i].Hint := Hints[i];
  end;
  AddPlanned(PlanSolidBlocks(Files, GM, EffectiveSolid(MO), SolidLevel(MO.Method)), Idx, MO, Groups);
end;

procedure GroupNewEntries(const Entries: TWriteEntryArray; const Idx: array of Integer;
  const MO: TModifyOptions; var Groups: TSolidGroupArray);
begin
  GroupEntries(Entries, Idx, [], MO, Groups);
end;

{ Clave para comparar nombres del archivo con los del disco (en Windows sin mayúsculas). }
function NameKey(const Name: string): string;
begin
  {$IFDEF WINDOWS}Result := LowerCase(Name);{$ELSE}Result := Name;{$ENDIF}
end;

{ Blocks of an archive being updated (a/u/f/d/m, ch):
  - an old block whose files all stay is copied as it is;
  - an old block that loses or replaces files is rewritten: the files that stay, in their
    order, with each replaced file (now from disk) in the place of its old version, using the
    method of the list with the same stages as the old one (or the old method), cut again by
    -s and the method's own limits; rewritten blocks with the same method are joined;
  - new files that replace nothing are planned like a new archive.
  With Recompress (an explicit -m with d/ch) every file is planned again; old files keep the
  kind of their block's method when the list has a method with the same stages.
  Keep/Old: which old files stay and their entry; NewIdx: the entries from disk. }
procedure PlanUpdate(A: TArchive; const Keep: array of Boolean; const Old: array of Integer;
  const Entries: TWriteEntryArray; const NewIdx: array of Integer; const MO: TModifyOptions;
  Recompress: Boolean; var Groups: TSolidGroupArray);
var
  GM: TGroupMethods;
  ByName: TStrIntMap;
  Used: array of Boolean;
  L, All: array of Integer;
  Hints: array of string;
  RM: array of string;
  RL: array of array of Integer;
  RC: array of Integer;
  Files: array of TPlanFile;
  Order: array of Integer;
  b, j, k, n, r, g: Integer;
  Whole: Boolean;
  M: string;

  function Signature(const Method: string): string;
  var
    St: TStringArray;
    i, p: Integer;
  begin
    Result := '';
    St := WithoutCipher(Method).Split(['+']);
    for i := 0 to High(St) do
    begin
      p := Pos(':', St[i]);
      if p > 0 then St[i] := Copy(St[i], 1, p - 1);
      Result := Result + '+' + LowerCase(Trim(St[i]));
    end;
  end;

  function RepackMethod(const OldMethod: string): string;
  var
    i: Integer;
    S: string;
  begin
    S := Signature(OldMethod);
    for i := 0 to High(GM) do
      if Signature(GM[i].Method) = S then Exit(GM[i].Method);
    Result := WithoutCipher(OldMethod);
  end;

begin
  if Recompress then
  begin
    n := 0;
    SetLength(All, Length(A.Files) + Length(NewIdx));
    SetLength(Hints, Length(All));
    for j := 0 to High(A.Files) do
      if Keep[j] and not A.Files[j].IsDir and not A.Files[j].IsLink then
      begin
        All[n] := Old[j];
        if (A.Files[j].DataBlock >= 0) and (A.Files[j].DataBlock <= High(A.DataBlocks)) then
          Hints[n] := WithoutCipher(A.DataBlocks[A.Files[j].DataBlock].Method)
        else
          Hints[n] := '';
        Inc(n);
      end;
    for k := 0 to High(NewIdx) do
    begin
      All[n] := NewIdx[k];
      Hints[n] := '';
      Inc(n);
    end;
    SetLength(All, n);
    SetLength(Hints, n);
    GroupEntries(Entries, All, Hints, MO, Groups);
    Exit;
  end;
  GM := DecodeMethod(MO.Method, BudgetThreads);
  ApplyMcOps(GM, MO.McOps);
  ByName.Init;
  for k := 0 to High(NewIdx) do ByName.Put(NameKey(Entries[NewIdx[k]].StoredName), k);
  SetLength(Used, Length(NewIdx));
  RM := nil; RL := nil; RC := nil;
  for b := 0 to High(A.DataBlocks) do
  begin
    n := 0;
    Whole := True;
    SetLength(L, A.DataBlocks[b].FileCount);
    for j := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
    begin
      if (j < 0) or (j > High(A.Files)) or A.Files[j].IsDir or A.Files[j].IsLink then Continue;
      if Keep[j] then
      begin
        L[n] := Old[j];
        Inc(n);
      end
      else
      begin
        Whole := False;
        k := ByName.Get(NameKey(A.Files[j].Name));
        if (k >= 0) and not Used[k] then
        begin
          Used[k] := True;
          L[n] := NewIdx[k];
          Inc(n);
        end;
      end;
    end;
    if n = 0 then Continue;
    if Whole then
    begin
      g := Length(Groups);
      SetLength(Groups, g + 1);
      Groups[g] := Default(TSolidGroup);
      Groups[g].Method := A.DataBlocks[b].Method;
      Groups[g].CopyFrom := A;
      Groups[g].CopyBlock := b;
      Groups[g].Files := Copy(L, 0, n);
      Continue;
    end;
    M := RepackMethod(A.DataBlocks[b].Method);
    r := 0;
    while (r < Length(RM)) and (RM[r] <> M) do Inc(r);
    if r = Length(RM) then
    begin
      SetLength(RM, r + 1); SetLength(RL, r + 1); SetLength(RC, r + 1);
      RM[r] := M; RL[r] := nil; RC[r] := 0;
    end;
    if RC[r] + n > Length(RL[r]) then SetLength(RL[r], 2 * (RC[r] + n));
    for j := 0 to n - 1 do RL[r][RC[r] + j] := L[j];
    Inc(RC[r], n);
  end;
  // rewritten blocks: their files in order, cut again
  for r := 0 to High(RM) do
  begin
    SetLength(Files, RC[r]);
    SetLength(Order, RC[r]);
    for j := 0 to RC[r] - 1 do
    begin
      Files[j] := Default(TPlanFile);
      Files[j].Name := Entries[RL[r][j]].StoredName;
      Files[j].Size := Entries[RL[r][j]].Meta.Size;
      Order[j] := j;
    end;
    AddPlanned(SplitRun(RM[r], Files, Order, EffectiveSolid(MO)), Copy(RL[r], 0, RC[r]), MO, Groups);
  end;
  // new files
  n := 0;
  SetLength(All, Length(NewIdx));
  for k := 0 to High(NewIdx) do
    if not Used[k] then
    begin
      All[n] := NewIdx[k];
      Inc(n);
    end;
  SetLength(All, n);
  GroupNewEntries(Entries, All, MO, Groups);
end;

{ Antepone Prefix (el módulo) a Target, a través de un temporal. }
procedure PrependToFile(const Target: string; const Prefix: TBytes);
var
  Src, Dst: TFileStream;
  Tmp: string;
begin
  Tmp := Target + '.prefix.tmp';
  Dst := TFileStream.Create(FsPath(Tmp), fmCreate);
  try
    try
      if Length(Prefix) > 0 then Dst.WriteBuffer(Prefix[0], Length(Prefix));
      Src := TFileStream.Create(FsPath(Target), fmOpenRead or fmShareDenyWrite);
      try
        Dst.CopyFrom(Src, 0);
      finally
        Src.Free;
      end;
    finally
      Dst.Free;
    end;
  except
    DeleteFile(FsPath(Tmp));
    raise;
  end;
  if not DeleteFile(FsPath(Target)) or not RenameFile(FsPath(Tmp), FsPath(Target)) then
    raise EFCreateError.CreateFmt('could not write %s', [Target]);
end;

function ReadWholeFile(const Name: string; MaxLen: Int64 = High(Int64)): TBytes;
var
  F: TFileStream;
  n: Int64;
begin
  F := TFileStream.Create(FsPath(Name), fmOpenRead or fmShareDenyWrite);
  try
    n := F.Size;
    if n > MaxLen then n := MaxLen;
    SetLength(Result, n);
    if n > 0 then F.ReadBuffer(Result[0], n);
  finally
    F.Free;
  end;
end;

{ ¿Cambia el cifrado de los datos? (entonces se reempaqueta todo con la contraseña nueva, o sin
  ninguna). -p- lo quita; una -p que no abre los datos cifrados (o datos en claro con -p) es
  una contraseña nueva. Una -p que sí los abre es solo para leer: nada cambia. }
function DataPasswordChanges(A: TArchive; const MO: TModifyOptions): Boolean;
var
  b: Integer;
  Enc: string;
begin
  Result := False;
  if A = nil then Exit;
  Enc := '';
  for b := 0 to High(A.DataBlocks) do
    if WithoutCipher(A.DataBlocks[b].Method) <> A.DataBlocks[b].Method then
    begin
      Enc := A.DataBlocks[b].Method;
      Break;
    end;
  if MO.NoDataPwd then Exit(Enc <> '');
  if MO.DataPassword = '' then Exit(False);
  Result := (Enc = '') or not CryptMethodPasswordOk(Enc, MO.DataPassword);
end;

{ Fecha (ns) del archivo o de su primer volumen; 0 si no se puede leer. }
function ArchiveMTime(const ArcName: string): Int64;
var
  M: TFileMeta;
begin
  Result := 0;
  if GetFileMeta(ArcName, M) then Exit(M.MTimeNs);
  if GetFileMeta(VolumeName(ArcName, 1), M) then Result := M.MTimeNs;
end;

{ Pone la fecha Ns al archivo (o a todos sus volúmenes). }
procedure SetArchiveMTime(const ArcName: string; Ns: Int64);
var
  i: Integer;
begin
  if FileExists(FsPath(ArcName)) then SetFileMTimeNs(ArcName, Ns);
  i := 1;
  while FileExists(FsPath(VolumeName(ArcName, i))) do
  begin
    SetFileMTimeNs(VolumeName(ArcName, i), Ns);
    Inc(i);
  end;
end;

{ a (agregar/reemplazar), u (solo si es más nuevo), f (solo actualizar lo que ya está),
  d (borrar). Sobre un archivo existente, los bloques que se conservan enteros se copian tal
  cual y los que pierden archivos se reempaquetan; se escribe un temporal que reemplaza al
  original al final. }
function CmdModify(const Cmd, ArcName: string; const Paths: TStringList; const MO: TModifyOptions): Integer;
var
  A: TArchive;
  Disk, Entries: TWriteEntryArray;
  NewIdx: array of Integer;
  Groups: TSolidGroupArray;
  Keep: array of Boolean;
  ByName: TStringList;
  Opt: TWriteOptions;
  St: TWriteStats;
  i, j, n, Removed, Replaced, Added: Integer;
  T0, T1: QWord;
  Missing, Verb, OldRR, VolBase, VolInfo, FinalName, L, Rel: string;
  Cpu0: Int64;
  SfxPrefix: TBytes;
  NVol: Integer;
  RRSize: Int64;
  Exists, Newer: Boolean;
  Recompress: Boolean;           // d con -m explícito: FreeArc recompila todos los bloques
  Old: array of Integer;         // índice en Entries de cada archivo viejo conservado (-1 si no)
  EntCount: Integer;
  Scopes: TCollectScopes;
  S: string;
  ChangeData: Boolean;
  DelSel: TBoolArray;
  DSel: TSelectOptions;
  OldTime, Newest: Int64;
  Skipped: TStringList;          // nombres guardados de los ilegibles (--sync no los borra)

  function AddEntry(const E: TWriteEntry): Integer;
  begin
    // Crece al doble; se recorta antes de usarse
    Result := EntCount;
    if Result >= Length(Entries) then SetLength(Entries, 2 * Result + 64);
    Inc(EntCount);
    Entries[Result] := E;
  end;

begin
  if ((Cmd = 'a') or (Cmd = 'u') or (Cmd = 'f') or (Cmd = 'j')) and (Paths.Count = 0) and (MO.StdinFile = '') then
  begin
    if Cmd = 'j' then ErrLn('ERROR: no archives to join specified') else ErrLn('ERROR: no files specified');
    Exit(1);
  end;
  if (Cmd = 'ch') and (Paths.Count > 0) then
  begin
    ErrLn('ERROR: this command takes no file names (it rewrites the whole archive)');
    Exit(1);
  end;
  // d sin nombres ni filtros: FreeArc lo rechaza (borraría todo con "*")
  if (Cmd = 'd') and (Paths.Count = 0) and not ContentFilters(MO.Sel) and (MO.Sel.ArcPath = '') then
  begin
    ErrLn('ERROR: no files specified (d needs names, patterns or a selection option)');
    Exit(1);
  end;
  // create tampoco reemplaza uno bloqueado (si no se puede abrir, p. ej. -hp sin contraseña,
  // no se sabe: se reemplaza)
  if MO.ForceNew and ArchiveExists(ArcName) then
  begin
    A := nil;
    try
      A := TArchive.Open(ArcName);
      Newer := A.Locked;
    except
      Newer := False;
    end;
    A.Free;
    if Newer then
    begin
      ErrLn('ERROR: ' + ArcName + ' is locked (k / -k): it cannot be replaced');
      Exit(1);
    end;
  end;
  Exists := ArchiveExists(ArcName) and not MO.ForceNew;   // create: como si no existiera
  if not Exists and ((Cmd = 'd') or (Cmd = 'f') or (Cmd = 'ch') or (Cmd = 'j')) then
  begin
    ErrLn('ERROR: does not exist: ' + ArcName);
    Exit(1);
  end;
  OldTime := 0;
  if Exists and MO.KeepTime then OldTime := ArchiveMTime(ArcName);
  if Exists then Verb := 'updating' else Verb := 'creating';
  OutLn(Paint('PArc ' + PARC_VERSION, '1') + Paint(' · ', '2') + Verb + ' archive: ' +
    BoolToStr(MO.ShownName <> '', MO.ShownName, ArcName));
  A := nil;
  Skipped := TStringList.Create;
  Skipped.Sorted := True;
  if Exists then A := TArchive.Open(ArcName);
  try
    // PArc ya no crea autoextraíbles, pero si el archivo ya traía un módulo delante se
    // guarda (lo que va antes del archivo) y se vuelve a poner al actualizarlo.
    SfxPrefix := nil;
    if (A <> nil) and (A.SFXSize > 0) then SfxPrefix := ReadWholeFile(ArcName, A.SFXSize);
    if (A <> nil) and A.Locked then
    begin
      ErrLn('ERROR: ' + ArcName + ' is locked (k / -k): it cannot be modified');
      Exit(1);
    end;
    // j: abrir los otros (antes de nada: si alguno falta o está dañado, no se escribe nada)
    if Cmd = 'j' then
    begin
      SetLength(JoinArcs, Paths.Count);
      for i := 0 to Paths.Count - 1 do JoinArcs[i] := nil;
      for i := 0 to Paths.Count - 1 do
      begin
        if ExpandFileName(Paths[i]) = ExpandFileName(ArcName) then
          raise EFOpenError.CreateFmt('cannot join an archive with itself: %s', [Paths[i]]);
        S := Paths[i];
        if IsVolumeSet(S, VolBase) then S := VolBase;
        JoinArcs[i] := TArchive.Open(S);
      end;
    end;
    Disk := nil;
    Scopes := nil;
    if (Cmd = 'a') or (Cmd = 'u') or (Cmd = 'f') then
    begin
      CollectEntries(Paths, ExpandFileName(ArcName), MO.Sel, MO.Recursive, MO.EpMode, Disk, Scopes);
    end;
    // --sync no borra los que no se pudieron leer (siguen en el disco)
    if UnreadableStored <> nil then
      for i := 0 to UnreadableStored.Count - 1 do Skipped.Add(NameKeyOf(UnreadableStored[i]));
    // -si: lo que llegó por stdin, ya volcado a un temporal, con el nombre pedido
    if (Cmd = 'a') and (MO.StdinFile <> '') then
    begin
      n := Length(Disk);
      SetLength(Disk, n + 1);
      Disk[n] := Default(TWriteEntry);
      Disk[n].DiskPath := MO.StdinFile;
      Disk[n].StoredName := SanitizePath(MO.StdinName);
      if MO.Sel.ArcPath <> '' then Disk[n].StoredName := MO.Sel.ArcPath + '/' + Disk[n].StoredName;
      GetFileMeta(MO.StdinFile, Disk[n].Meta);
      Disk[n].Meta.MTimeNs := Int64(DateTimeToUnix(Now, False)) * 1000000000;
    end;
    // --nodates: lo nuevo va sin fecha (al extraerlo queda la de la extracción)
    if MO.NoDates then
      for i := 0 to High(Disk) do Disk[i].Meta.MTimeNs := 0;
    if ((Cmd = 'a') or (Cmd = 'u') or (Cmd = 'f')) and (Length(Disk) = 0) and not Exists then
    begin
      // como FreeArc ("No files to archive"): no se crea un archivo vacío
      ErrLn('ERROR: no files to add');
      Exit(1);
    end;

    Entries := nil;
    EntCount := 0;
    NewIdx := nil;
    Removed := 0; Replaced := 0; Added := 0;
    Groups := nil;
    // Cmdline.hs: con los comandos que copian (d, ch, j), un -m explícito implica
    // --recompress: los bloques viejos se rehacen con ese método en vez de copiarse. Cambiar
    // la contraseña (ch -p/-hp/-p-) también rehace todo.
    ChangeData := DataPasswordChanges(A, MO);
    Recompress := MO.Recompress or (((Cmd = 'd') or (Cmd = 'ch') or (Cmd = 'j')) and MO.MethodGiven)
                  or ChangeData;
    if Cmd = 'j' then
      PlanJoin(A, Recompress, Entries, Groups, Added, Replaced)
    else
    begin
    // Archivos viejos: cuáles se conservan
    if A <> nil then
    begin
      if Cmd = 'd' then
      begin
        DSel := MO.Sel;
        DSel.Patterns := Paths;
        DelSel := SelectArchive(A, DSel);
      end;
      ByName := TStringList.Create;
      try
        ByName.Sorted := True;
        ByName.Duplicates := dupIgnore;
        for i := 0 to High(Disk) do ByName.AddObject(NameKey(Disk[i].StoredName), TObject(PtrInt(i)));
        SetLength(Keep, Length(A.Files));
        SetLength(Old, Length(A.Files));
        for j := 0 to High(A.Files) do
        begin
          Keep[j] := True;
          Old[j] := -1;
          if Cmd = 'd' then
            Keep[j] := not DelSel[j]
          else
          begin
            i := ByName.IndexOf(NameKey(A.Files[j].Name));
            if i >= 0 then
            begin
              i := PtrInt(ByName.Objects[i]);
              if A.Files[j].IsDir and Disk[i].Meta.IsDir then
                Disk[i].Meta.Size := -1   // el directorio ya está: no duplicarlo
              else
              begin
                // u y f solo reemplazan si el del disco es más nuevo (comparado en segundos,
                // la precisión de .arc)
                Newer := (Disk[i].Meta.MTimeNs div 1000000000) > (MetaFromArchive(A.Files[j]).MTimeNs div 1000000000);
                if (Cmd = 'a') or Newer then
                begin
                  Keep[j] := False;
                  Inc(Replaced);
                end
                else
                  Disk[i].Meta.Size := -1;  // se queda el del archivo
              end;
            end
            else if MO.Sync and InScopes(A.Files[j].Name, Scopes) and UnderArcPath(MO.Sel, A.Files[j].Name, Rel)
                    and Selected(MO.Sel, Rel, A.Files[j].IsDir, A.Files[j].Size,
                                 MetaFromArchive(A.Files[j]).MTimeNs, False) then
            begin
              // --sync: dentro de lo que cubren los argumentos, elegido por los filtros y ya
              // no está en el disco (salvo que exista pero no se pudo leer)
              Keep[j] := Skipped.IndexOf(NameKeyOf(A.Files[j].Name)) >= 0;
            end;
          end;
          if not Keep[j] and ((Cmd = 'd') or (i < 0)) then Inc(Removed);
        end;
      finally
        ByName.Free;
      end;
      // Entradas conservadas (en el orden del archivo)
      for j := 0 to High(A.Files) do
        if Keep[j] then
        begin
          Old[j] := AddEntry(Default(TWriteEntry));
          Entries[Old[j]].StoredName := A.Files[j].Name;
          Entries[Old[j]].Meta := MetaFromArchive(A.Files[j]);
          Entries[Old[j]].SrcArc := A;
          Entries[Old[j]].SrcIndex := j;
        end;
    end;
    // Archivos nuevos del disco (f solo actualiza: no agrega los que no estaban)
    for i := 0 to High(Disk) do
    begin
      if Disk[i].Meta.Size < 0 then Continue;
      // f solo actualiza lo que ya está: ni archivos ni directorios nuevos
      if Cmd = 'f' then
      begin
        n := 0;
        if A <> nil then
          for j := 0 to High(A.Files) do
            if NameKey(A.Files[j].Name) = NameKey(Disk[i].StoredName) then n := 1;
        if n = 0 then Continue;
      end;
      j := AddEntry(Disk[i]);
      if not Disk[i].Meta.IsDir and not Disk[i].Meta.IsLink then
      begin
        SetLength(NewIdx, Length(NewIdx) + 1);
        NewIdx[High(NewIdx)] := j;
        Inc(Added);
      end;
    end;
    Dec(Added, Replaced);
    if Added < 0 then Added := 0;
    SetLength(Entries, EntCount);
    if A = nil then
      GroupNewEntries(Entries, NewIdx, MO, Groups)
    else
      PlanUpdate(A, Keep, Old, Entries, NewIdx, MO, Recompress, Groups);
    end;
    // m/mf/-d/-df: lo que viene del disco (no -si) y entra en el archivo
    MovedEntries := nil;
    if MO.MoveMode > 0 then
      for i := 0 to High(Entries) do
        if (Entries[i].SrcArc = nil) and (Entries[i].DiskPath <> '') and (Entries[i].DiskPath <> MO.StdinFile) then
        begin
          SetLength(MovedEntries, Length(MovedEntries) + 1);
          MovedEntries[High(MovedEntries)] := Entries[i];
        end;

    // Avisar de una vez qué métodos todavía no se pueden comprimir
    Missing := '';
    for i := 0 to High(Groups) do
      if (Groups[i].CopyFrom = nil) and not EncoderAvailable(WithoutCipher(Groups[i].Method)) then
        Missing := Missing + LineEnding + '  ' + Groups[i].Method;
    if Missing <> '' then
    begin
      ErrLn('ERROR: no encoder yet for:' + Missing);
      for i := 0 to High(Groups) do
        if TornadoRequested(WithoutCipher(Groups[i].Method)) then
        begin
          ErrLn('The tor (Tornado) method was removed after PArc 0.0.5; use plz instead ' +
            '(plz:1..7; tor:3/4/5/6 -> plz:1/2/3/4, xtor -> 4x4:plz).');
          Break;
        end;
      // REP de FreeArc ya no está: su reemplazo es orep (otros parámetros)
      if (Pos(' rep', Missing) > 0) or (Pos('+rep', Missing) > 0) then
        ErrLn('  (rep was replaced by orep: -morep:<window>:l<min length>, see docs/USO.md)');
      Exit(3);
    end;

    Opt := Default(TWriteOptions);   // KeepTemp/Comment: los registros locales no se inicializan solos
    Opt.DirMethod := DIR_METHOD;
    Opt.Parallel := True;
    Opt.KeepTemp := True;            // el original se cierra antes de reemplazarlo (Windows)
    if A <> nil then Opt.Comment := A.Comment;
    if MO.CommentGiven then Opt.Comment := MO.Comment;
    Opt.Locked := MO.Lock;
    Opt.ChangePassword := ChangeData;
    // El tamaño para el % recomendado es el de los datos (aproximado: lo de entrada)
    OldRR := '';
    if A <> nil then OldRR := A.Recovery;
    RRSize := 0;
    for i := 0 to High(Entries) do Inc(RRSize, Entries[i].Meta.Size);
    Opt.Recovery := ResolveRecovery(MO.Recovery, OldRR, RRSize);
    Opt.Encryption := MO.Encryption;
    Opt.DataPassword := MO.DataPassword;
    Opt.HeadersPassword := MO.HeadersPassword;
    // Un archivo con -hp sigue con los encabezados cifrados aunque al actualizarlo no se repita
    // -hp (antes quedaban en claro): con la contraseña principal, si es la que los abre
    if (A <> nil) and (MO.HeadersPassword = '') and not MO.NoDataPwd and not MO.NoHeadPwd and
       (WithoutCipher(A.Footer.Method) <> A.Footer.Method) then
    begin
      if ChangeData and (MO.DataPassword <> '') then
        Opt.HeadersPassword := MO.DataPassword    // ch -p<nueva>: los encabezados también
      else if (ArchivePassword <> '') and CryptMethodPasswordOk(A.Footer.Method, ArchivePassword) then
        Opt.HeadersPassword := ArchivePassword
      else
        ErrLn('Warning: the archive headers were encrypted with another password; give it with -hp to keep them encrypted');
    end;
    // Volúmenes: -v, o el tamaño que ya tenían (el del primero) si se actualiza uno partido
    Opt.VolumeSize := MO.VolumeSize;
    if (Opt.VolumeSize = 0) and IsVolumeSet(ArcName, VolBase) then
      Opt.VolumeSize := FileSizeOf(VolumeName(ArcName, 1));
    Newest := 0;
    for i := 0 to High(Entries) do
      if Entries[i].Meta.MTimeNs > Newest then Newest := Entries[i].Meta.MTimeNs;
    T0 := GetTickCount64;
    Cpu0 := ProcessCpuMs;
    St := WriteArchive(ArcName, Entries, Groups, Opt, @LogLine);
    T1 := GetTickCount64;
  finally
    A.Free;
    Skipped.Free;
    for i := 0 to High(JoinArcs) do JoinArcs[i].Free;
    JoinArcs := nil;
  end;
  FinishArchive(ArcName, Opt.VolumeSize);
  FinalName := ArcName;
  // PArc ya no crea autoextraíbles; si el archivo ya traía un módulo delante, se conserva
  if Length(SfxPrefix) > 0 then
  begin
    PrependToFile(ArcName, SfxPrefix);
    // el archivo se reescribió: que siga siendo ejecutable
    {$IFDEF UNIX}FpChmod(ArcName, &755);{$ENDIF}
  end;
  // -tk: la fecha que tenía; -tl: la del archivo más nuevo de adentro
  if MO.KeepTime and (OldTime <> 0) then SetArchiveMTime(ArcName, OldTime)
  else if MO.TimeToLast and (Newest > 0) then SetArchiveMTime(ArcName, Newest);
  VolInfo := '';
  if Opt.VolumeSize > 0 then
  begin
    NVol := 0;
    while FileExists(FsPath(VolumeName(ArcName, NVol + 1))) do Inc(NVol);
    VolInfo := Format(', %d volume(s) of %d bytes: %s ...', [NVol, Opt.VolumeSize, VolumeName(ArcName, 1)]);
  end;
  if MO.ShownName <> '' then FinalName := MO.ShownName;
  if Length(SfxPrefix) > 0 then OutLn('(self-extracting stub kept)');
  if VolInfo <> '' then OutLn(Copy(VolInfo, 3, MaxInt));
  L := 'Compressed ' + Count(St.Files, 'file');
  if St.Dirs > 0 then L := L + ' and ' + Count(St.Dirs, 'folder');
  L := L + ', ' + Num(St.Bytes) + ' => ' + Num(St.ArcSize) + ' bytes';
  if St.Bytes > 0 then L := L + ' · ratio ' + Paint(Format('%.2f%%', [100.0 * St.ArcSize / St.Bytes]), '1');
  OutLn(L);
  if Exists then
    OutLn(Format('Added %s, replaced %s, deleted %s', [Num(Added), Num(Replaced), Num(Removed)]));
  PrintTimes('Compression', T0, T1, Cpu0, ProcessCpuMs, St.Bytes);
  PrintResult(0);
  Result := 0;
  if (Unreadable <> nil) and (Unreadable.Count > 0) then
  begin
    ErrLn(Format('Warning: %d file(s) could not be read and were not added (if present, the previous version was kept)',
      [Unreadable.Count]));
    Result := EXIT_WARNINGS;
  end;
end;

{ m/mf/-d/-df: borra del disco lo que quedó en el archivo, solo si no cambió desde que se leyó
  (tamaño y fecha). Enlaces: se borra el enlace, nunca su destino. Con m también los
  directorios agregados que quedaron vacíos (los más profundos primero). Devuelve cuántos no se
  pudieron borrar. }
function DeleteMoved(Mode: Integer): Integer;
var
  i, Files, Dirs: Integer;
  M: TFileMeta;
  DirList: TStringList;
  Same: Boolean;
begin
  Result := 0; Files := 0; Dirs := 0;
  DirList := TStringList.Create;
  try
    for i := 0 to High(MovedEntries) do
      with MovedEntries[i] do
      begin
        if Meta.IsDir and not Meta.IsLink then
        begin
          if Mode = 1 then DirList.Add(DiskPath);
          Continue;
        end;
        if Meta.IsLink then Same := GetLinkMeta(DiskPath, M) and M.IsLink
        else Same := not GetLinkMeta(DiskPath, M) and GetFileMeta(DiskPath, M) and not M.IsDir and
                     (M.Size = Meta.Size) and (M.MTimeNs = Meta.MTimeNs);
        if not Same then
        begin
          ErrLn('Warning: ' + DiskPath + ' changed after it was archived: not deleted');
          Inc(Result);
          Continue;
        end;
        // un enlace a un directorio en Windows es un directorio: RemoveDir quita el enlace
        if DeleteFile(FsPath(DiskPath)) or (Meta.IsLink and RemoveDir(FsPath(DiskPath))) then Inc(Files)
        else
        begin
          ErrLn('Warning: could not delete ' + DiskPath);
          Inc(Result);
        end;
      end;
    // los más largos (más profundos) primero; uno con algo adentro (no archivado) queda
    DirList.Sort;
    for i := DirList.Count - 1 downto 0 do
      if RemoveDir(FsPath(DirList[i])) then Inc(Dirs);
  finally
    DirList.Free;
  end;
  OutLn(Format('Deleted from disk: %s%s', [Count(Files, 'file'), BoolToStr(Mode = 1, ' and ' + Count(Dirs, 'folder'), '')]));
end;

var
  KeyDigest: string = '';   // -kf: BLAKE2b del archivo clave en hex ('' = sin)

{ Las contraseñas que se piden por consola también llevan el archivo clave (-kf). }
procedure AddPromptedPassword(const S: string);
begin
  AddArchivePassword(MixKeyFile(S, KeyDigest));   // se suma a las ya dadas (-p y -hp pueden ser distintas)
end;

{ --print-config: the preset table, what each -m gives with the current threads, and the file
  groups. }
procedure PrintConfig;
const
  LEVELS: array[0..11] of string = ('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'x', 'xx');
var
  L: TStringArray;
  i, k: Integer;
  GM: TGroupMethods;
begin
  OutLn('; PArc ' + PARC_VERSION + ' built-in configuration');
  OutLn('; Preset rows: name [levels] [$group] = chain; N is the level digit; "with K+ threads"');
  OutLn('; is the variant used with at least K threads (see -mt / PARC_THREADS)');
  OutLn('[Compression methods]');
  L := PresetTableLines;
  for i := 0 to High(L) do OutLn(L[i]);
  OutLn('');
  OutLn(Format('; Presets as resolved now (%d thread(s)); "$group=" lines override the default', [BudgetThreads]));
  OutLn('[Presets]');
  for i := 0 to High(LEVELS) do
  begin
    GM := DecodeMethod(LEVELS[i], BudgetThreads);
    for k := 0 to High(GM) do
      if GM[k].Group = '' then OutLn('-m' + LEVELS[i] + ' = ' + GM[k].Method)
      else OutLn('-m' + LEVELS[i] + ' ' + GM[k].Group + '=' + GM[k].Method);
  end;
  OutLn('');
  OutLn('; File groups: "$group" headers followed by their masks; <other> = files matching none');
  OutLn('[File groups]');
  L := FileGroupLines;
  for i := 0 to High(L) do OutLn(L[i]);
end;

{ t sobre un archivo (-t después de escribir, -tp antes de modificarlo). Devuelve el código de
  salida del test; nunca lanza. }
function TestArchiveFile(const ArcName: string; const Base: TExtractOptions): Integer;
var
  A: TArchive;
  TOpt: TExtractOptions;
begin
  TOpt := Base;
  TOpt.Sel := nil;
  TOpt.Filter := nil;
  TOpt.FlatNames := False;
  TOpt.ToStdout := False;
  try
    A := TArchive.Open(ArcName);
    try
      Result := CmdExtract(A, 't', TOpt);
    finally
      A.Free;
    end;
  except
    on E: EPasswordRequired do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 5; end;
    on E: EBadPassword do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 5; end;
    on E: EOperationCancelled do begin ClearProgress; ErrLn('Cancelled.'); Result := EXIT_CANCELLED; end;
    on E: EArcCorrupt do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 2; end;
    on E: EUnsupportedMethod do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 3; end;
    on E: Exception do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 4; end;
  end;
end;

{ Solo para los tests (tests/cli_options.sh): PARC_TEST_FLIP=<offset> invierte un byte del
  archivo recién escrito, antes del -t, para comprobar que el test posterior lo detecta. Un
  offset negativo cuenta desde el final. }
procedure TestFlipHook(const ArcName: string);
var
  F: TFileStream;
  Ofs: Int64;
  B: Byte;
  V: string;
begin
  V := GetEnvironmentVariable('PARC_TEST_FLIP');
  if V = '' then Exit;
  Ofs := StrToInt64Def(V, 0);
  F := TFileStream.Create(FsPath(ArcName), fmOpenReadWrite);
  try
    if Ofs < 0 then Ofs := F.Size + Ofs;
    if (Ofs < 0) or (Ofs >= F.Size) then Exit;
    F.Position := Ofs;
    F.ReadBuffer(B, 1);
    B := B xor $55;
    F.Position := Ofs;
    F.WriteBuffer(B, 1);
  finally
    F.Free;
  end;
end;

{ -mc...: True si S (sin "-mc") es una operación sobre los algoritmos y no un método que empieza
  con "c" (como -mcm). Agrega a Ops "grupos|cosa". Sintaxis: -mc-<alg>, -mc<alg>-, -mc-$grupo,
  -mc$g1,$g2:-<alg>; abreviaturas de una letra como FreeArc/RAR: d=delta, e=exe, l=lzp,
  r=orep (y -mc-rep), z=dict, a=$wav, c=$bmp, t=$text. }
function ParseMcOption(const Rest: string; Ops: TStrings): Boolean;
var
  Groups, Op, What: string;
  p: Integer;
begin
  Result := False;
  if Rest = '' then Exit;
  if not ((Rest[1] in ['-', '$', ':']) or (Rest[Length(Rest)] = '-')) then Exit;
  Groups := '';
  Op := Rest;
  if Rest[1] = '$' then
  begin
    p := 1;
    while (p <= Length(Rest)) and not (Rest[p] in [':', '-', '+']) do Inc(p);
    Groups := Copy(Rest, 1, p - 1);
    Op := Copy(Rest, p, MaxInt);
    if (Op <> '') and (Op[1] = ':') then Delete(Op, 1, 1);
    if Op = '' then Exit;     // "-mc$grupo" a secas: no es una operación
  end
  else if Op[1] = ':' then Delete(Op, 1, 1);
  if (Op <> '') and (Op[1] = '-') then What := Copy(Op, 2, MaxInt)
  else if (Op <> '') and (Op[Length(Op)] = '-') then What := Copy(Op, 1, Length(Op) - 1)
  else Exit;
  What := LowerCase(What);
  case What of
    'd': What := 'delta';
    'e': What := 'exe';
    'l': What := 'lzp';
    'r', 'rep': What := 'orep';   // REP se reemplazó por OREP
    'z': What := 'dict';
    'a': What := '$wav';
    'c': What := '$bmp';
    't': What := '$text';
    'dispack070': What := 'dispack';
  end;
  if What = '' then Exit;
  Ops.Add(Groups + '|' + What);
  Result := True;
end;

function AllDigits(const S: string): Boolean;
var
  c: Char;
begin
  Result := S <> '';
  for c in S do
    if not (c in ['0'..'9']) then Exit(False);
end;

procedure Fail(const Msg: string);
begin
  ErrLn('ERROR: ' + Msg);
  Halt(1);
end;

var
  Cmd, ArcName, Pwd2, S, AgFmt, KeyFile: string;
  VolSize, V: Int64;
  A: TArchive;
  Opt: TExtractOptions;
  MO: TModifyOptions;
  Filter, Excludes, Includes, McOps: TStringList;
  Sel: TBoolArray;
  i, Code, Tries, TCode: Integer;
  Retry, ShowProgress, Writing, ToStdout, AgGiven, OverwriteGiven, YesAll: Boolean;
  TestAfter, PreTest, PrintCfg: Boolean;
  DPwd, HPwd: string;
  Cipher: TCipherChoice;
  Rel, BaseCmd, OldPwd: string;
  MoveOpt: Integer;
  PwdOpt, NoDataPwd, NoHeadPwd: Boolean;
  F: TFileStream;
  CommentBytes: TBytes;
begin
  Cmd := '';
  if ArgCount >= 1 then Cmd := Arg(1);
  if (Cmd = '--version') or (Cmd = '-V') or (Cmd = 'version') then
  begin
    OutLn('PArc ' + PARC_VERSION);
    Halt(0);
  end;
  if (Cmd = '--help') or (Cmd = '-h') then
  begin
    LongHelp;
    Halt(0);
  end;
  if Cmd = 'help' then
  begin
    if ArgCount < 2 then LongHelp
    else if not CommandHelp(Arg(2)) then
    begin
      ErrLn('ERROR: unknown command "' + Arg(2) + '"');
      ErrLn('Run "parc help" for usage.');
      Halt(1);
    end;
    Halt(0);
  end;
  // --print-config en cualquier lugar (también sin comando), con -mt antes si se quiere ver
  // lo que da cada preset con otra cantidad de hilos
  PrintCfg := False;
  for i := 1 to ArgCount do
    if Arg(i) = '--print-config' then PrintCfg := True
    else if (Copy(Arg(i), 1, 3) = '-mt') and AllDigits(Copy(Arg(i), 4, MaxInt)) then
      SetBudgetThreads(StrToIntDef(Copy(Arg(i), 4, MaxInt), 0));
  if PrintCfg then
  begin
    PrintConfig;
    Halt(0);
  end;
  if ArgCount < 2 then
  begin
    if Cmd = '' then
    begin
      ShortHelp;
      Halt(0);
    end;
    ErrLn('ERROR: missing archive for command "' + Cmd + '"');
    ErrLn('Run "parc help ' + Cmd + '" for usage.');
    Halt(1);
  end;
  if not IsCommand(Cmd) then
  begin
    ErrLn('ERROR: unknown command "' + Cmd + '"');
    ErrLn('Run "parc help" for usage.');
    Halt(1);
  end;
  Opt := Default(TExtractOptions);
  Opt.Overwrite := owSkip;
  ArcName := '';
  MO := Default(TModifyOptions);
  MO.Method := DEFAULT_METHOD;
  MO.EpMode := -1;
  MO.Sel := DefaultSelect;
  Filter := TStringList.Create;
  Excludes := TStringList.Create;
  Includes := TStringList.Create;
  McOps := TStringList.Create;
  MO.Sel.Excludes := Excludes;
  MO.Sel.Includes := Includes;
  MO.McOps := McOps;
  MO.Recovery := '--';
  MO.Encryption := 'chacha';
  DPwd := '--'; HPwd := '--';   // '--' = no se dio la opción (como Cmdline.hs)
  Code := 0;
  ShowProgress := True;
  AgGiven := False; AgFmt := '';
  OverwriteGiven := False; YesAll := False;
  TestAfter := False; PreTest := False;
  KeyFile := '';
  MoveOpt := 0; OldPwd := '';
  NoDataPwd := False; NoHeadPwd := False;
  try
    try
    for i := 2 to ArgCount do
    begin
      S := Arg(i);
      if (Length(S) > 1) and (S[1] = '-') then
      begin
        if Copy(S, 1, 3) = '-dp' then
        begin
          if Length(S) = 3 then Fail('-dp needs an attached directory (-dp<dir>)');
          Opt.DestDir := Copy(S, 4, MaxInt);
        end
        else if S = '--no-progress' then ShowProgress := False
        else if S = '--verbose' then ListFiles := True
        else if S = '--print-config' then
        else if (Copy(S, 1, 2) = '-v') and ParseVolumeSize(Copy(S, 3, MaxInt), VolSize) then
          MO.VolumeSize := VolSize
        else if S = '-o+' then begin Opt.Overwrite := owAll; OverwriteGiven := True; end
        else if S = '-o-' then begin Opt.Overwrite := owSkip; OverwriteGiven := True; end
        else if S = '-y' then YesAll := True
        else if S = '-snld' then Opt.UnsafeLinks := True
        else if S = '-so' then Opt.ToStdout := True
        else if Copy(S, 1, 3) = '-si' then
        begin
          MO.StdinName := Copy(S, 4, MaxInt);
          if MO.StdinName = '' then MO.StdinName := 'stdin';
        end
        else if S = '--recompress' then MO.Recompress := True
        else if S = '--sync' then MO.Sync := True
        else if S = '--nodates' then MO.NoDates := True
        else if S = '--dirs' then MO.Sel.Dirs := dmAlways
        else if S = '-ed' then MO.Sel.Dirs := dmNever
        else if S = '-kb' then Opt.KeepBroken := True
        else if S = '-k' then MO.Lock := True
        else if S = '-d' then MoveOpt := 1
        else if S = '-df' then MoveOpt := 2
        else if Copy(S, 1, 18) = '--archive-comment=' then
        begin
          MO.Comment := Copy(S, 19, MaxInt);
          MO.CommentGiven := True;
        end
        else if S = '-z' then
        begin
          // -z: el comentario por stdin (hasta EOF)
          if InIsConsole then ErrLn('Enter the archive comment, end with Ctrl-D (Ctrl-Z on Windows):');
          S := IncludeTrailingPathDelimiter(GetTempDir) + Format('parc-cmt-%d.tmp', [GetProcessID]);
          RegisterTempFile(S);
          StdinToFile(S);
          MO.Comment := RawByteString(StringOf(ReadWholeFile(S)));
          DeleteFile(FsPath(S));
          MO.CommentGiven := True;
        end
        else if Copy(S, 1, 2) = '-z' then
        begin
          CommentBytes := ReadWholeFile(Copy(S, 3, MaxInt), 1 shl 20);
          SetString(MO.Comment, PAnsiChar(CommentBytes), Length(CommentBytes));
          MO.CommentGiven := True;
        end
        else if Copy(S, 1, 3) = '-op' then OldPwd := Copy(S, 4, MaxInt)
        else if S = '-tk' then MO.KeepTime := True
        else if S = '-tl' then MO.TimeToLast := True
        else if S = '-t' then TestAfter := True
        else if S = '-tp' then PreTest := True
        else if Copy(S, 1, 3) = '-ta' then
        begin
          if not ParseAbsTime(Copy(S, 4, MaxInt), MO.Sel.TimeAfter) then Fail('bad time in ' + S + ' (YYYYMMDD[hhmmss])');
          MO.Sel.HasAfter := True;
        end
        else if Copy(S, 1, 3) = '-tb' then
        begin
          if not ParseAbsTime(Copy(S, 4, MaxInt), MO.Sel.TimeBefore) then Fail('bad time in ' + S + ' (YYYYMMDD[hhmmss])');
          MO.Sel.HasBefore := True;
        end
        else if Copy(S, 1, 3) = '-tn' then
        begin
          // más nuevo que el período: mtime >= ahora - período
          if not ParsePeriod(Copy(S, 4, MaxInt), V) then Fail('bad period in ' + S + ' (e.g. 10d, 2h30m, 1w)');
          if not MO.Sel.HasAfter or (NowNs - V > MO.Sel.TimeAfter) then MO.Sel.TimeAfter := NowNs - V;
          MO.Sel.HasAfter := True;
        end
        else if Copy(S, 1, 3) = '-to' then
        begin
          if not ParsePeriod(Copy(S, 4, MaxInt), V) then Fail('bad period in ' + S + ' (e.g. 10d, 2h30m, 1w)');
          if not MO.Sel.HasBefore or (NowNs - V < MO.Sel.TimeBefore) then MO.Sel.TimeBefore := NowNs - V;
          MO.Sel.HasBefore := True;
        end
        else if (Copy(S, 1, 3) = '-sm') and (Length(S) > 3) and (S[4] in ['0'..'9']) then
        begin
          if not ParseSizeArg(Copy(S, 4, MaxInt), 1, MO.Sel.SizeMore) then Fail('bad size in ' + S);
        end
        else if (Copy(S, 1, 3) = '-sl') and (Length(S) > 3) and (S[4] in ['0'..'9']) then
        begin
          if not ParseSizeArg(Copy(S, 4, MaxInt), 1, MO.Sel.SizeLess) then Fail('bad size in ' + S);
        end
        else if (Copy(S, 1, 3) = '-mt') and AllDigits(Copy(S, 4, MaxInt)) then
          // ya aplicado arriba (antes de cualquier otra cosa)
        else if (Copy(S, 1, 3) = '-mc') and ParseMcOption(Copy(S, 4, MaxInt), McOps) then
        else if Copy(S, 1, 2) = '-m' then
        begin
          MO.Method := Copy(S, 3, MaxInt);   // preset (0..9, x, ...) o método explícito
          MO.MethodGiven := True;
        end
        else if Copy(S, 1, 2) = '-x' then
        begin
          if Length(S) = 2 then Fail('-x needs an attached pattern (-x<pattern>, e.g. -x*.txt)');
          AddItemOrList(Copy(S, 3, MaxInt), Excludes);
        end
        else if Copy(S, 1, 2) = '-n' then
        begin
          if Length(S) = 2 then Fail('-n needs an attached pattern (-n<pattern>, e.g. -n*.txt)');
          AddItemOrList(Copy(S, 3, MaxInt), Includes);
          MO.Sel.IncludeGiven := True;
        end
        else if Copy(S, 1, 3) = '-ep' then
        begin
          case Copy(S, 4, MaxInt) of
            '': MO.EpMode := 0;
            '1': MO.EpMode := 1;
            '2': MO.EpMode := -1;
          else
            Fail('unsupported ' + S + ' (use -ep, -ep1 or -ep2)');
          end;
        end
        else if Copy(S, 1, 3) = '-ap' then
        begin
          MO.Sel.ArcPath := SanitizePath(Copy(S, 4, MaxInt));
          if MO.Sel.ArcPath = '' then Fail('-ap needs a directory (-ap<dir>)');
        end
        else if Copy(S, 1, 3) = '-ag' then
        begin
          AgGiven := True;
          AgFmt := Copy(S, 4, MaxInt);
        end
        else if Copy(S, 1, 2) = '-w' then
        begin
          if Length(S) = 2 then Fail('-w needs an attached directory (-w<dir>)');
          WorkDir := Copy(S, 3, MaxInt);
        end
        else if (Copy(S, 1, 3) = '-lc') or (Copy(S, 1, 3) = '-ld') then
        begin
          if (Copy(S, 4, MaxInt) = '-') or (Copy(S, 4, MaxInt) = '0') then V := 0
          else if not ParseMemLimit(Copy(S, 4, MaxInt), V) then
            Fail('bad memory size in ' + S + ' (e.g. 512m, 2g, 50%; a bare number is MB)');
          if S[3] = 'c' then CompressMemLimit := V else Opt.MemLimit := V;
        end
        else if Copy(S, 1, 3) = '-kf' then
        begin
          if Length(S) = 3 then Fail('-kf needs an attached file name (-kf<file>)');
          KeyFile := Copy(S, 4, MaxInt);
        end
        // -s- no sólido; -s<mem> tope de bytes por bloque; -s<N>f tope de archivos
        else if Copy(S, 1, 3) = '-rr' then MO.Recovery := Copy(S, 4, MaxInt)
        else if S = '-r' then MO.Recursive := True
        else if (Copy(S, 1, 2) = '-s') and ParseSolidSpec(Copy(S, 3, MaxInt), MO.Solid) then
          MO.SolidGiven := True
        else if Copy(S, 1, 3) = '-hp' then HPwd := Copy(S, 4, MaxInt)
        else if Copy(S, 1, 2) = '-p' then DPwd := Copy(S, 3, MaxInt)
        else if Copy(S, 1, 4) = '-ae=' then MO.Encryption := Copy(S, 5, MaxInt)
        else if Copy(S, 1, 13) = '--encryption=' then MO.Encryption := Copy(S, 14, MaxInt)
        else
        begin
          ErrLn('Unknown option: ' + S);
          Halt(1);
        end;
      end
      else if ArcName = '' then ArcName := S
      else AddItemOrList(S, Filter);   // @lista: un nombre o patrón por línea
    end;
    except
      on E: EFOpenError do begin ErrLn('ERROR: ' + FileErrorText(E.Message, True)); Halt(4); end;
    end;
    if ArcName = '' then
    begin
      Usage;
      Halt(1);
    end;
    // -ag: fecha y hora agregadas al nombre (antes de la extensión), como FreeArc
    if AgGiven and (ArcName <> '-') then ArcName := AutoGenName(ArcName, AgFmt, Now);
    if (ArcName <> '-') and (LowerCase(ExtractFileExt(ArcName)) = '.arc') then
    begin
      ErrLn('ERROR: PArc no longer reads or writes .arc (only .parc). For .arc use FreeArc-ex.');
      Halt(1);
    end;
    // Los comandos nuevos son formas de a / ch (como en FreeArc):
    //   m, mf = a + borrar del disco; create = a desde cero; c = ch con comentario;
    //   k = ch con -k; rr<spec> = ch -rr<spec>; j = juntar archivos
    BaseCmd := Cmd;
    if (Cmd = 'm') or (Cmd = 'mf') then
    begin
      BaseCmd := 'a';
      if Cmd = 'm' then MO.MoveMode := 1 else MO.MoveMode := 2;
    end
    else if Cmd = 'create' then begin BaseCmd := 'a'; MO.ForceNew := True; end
    else if Cmd = 'c' then
    begin
      BaseCmd := 'ch';
      if not MO.CommentGiven then Fail('c needs the comment: -z<file>, -z (stdin) or --archive-comment=<text>');
    end
    else if Cmd = 'k' then begin BaseCmd := 'ch'; MO.Lock := True; end
    else if Copy(Cmd, 1, 2) = 'rr' then begin BaseCmd := 'ch'; MO.Recovery := Copy(Cmd, 3, MaxInt); end;
    if MoveOpt > 0 then
    begin
      if (BaseCmd <> 'a') and (BaseCmd <> 'u') and (BaseCmd <> 'f') then Fail('-d and -df are only valid with a, u, f');
      if MO.MoveMode = 0 then MO.MoveMode := MoveOpt;
    end;
    Writing := (BaseCmd = 'a') or (BaseCmd = 'u') or (BaseCmd = 'f') or (BaseCmd = 'd') or
               (BaseCmd = 'ch') or (BaseCmd = 'j');
    if (MO.Lock or MO.CommentGiven) and not Writing then Fail('-k, -z and --archive-comment are only valid with commands that write');
    if MO.ForceNew and (ArcName = '-') then MO.ForceNew := False;
    if (WorkDir <> '') and not DirectoryExists(FsPath(WorkDir)) then
      Fail('-w: directory does not exist: ' + WorkDir);
    Opt.TempDir := WorkDir;
    if MO.Sync and (BaseCmd <> 'a') and (BaseCmd <> 'u') then Fail('--sync is only valid with commands a and u');
    if (TestAfter or PreTest) and not Writing then Fail('-t and -tp are only valid with commands that write');
    if (MO.MoveMode > 0) and (ArcName = '-') then Fail('m/mf/-d/-df cannot be used with an archive on stdout');
    // -y: sí a todo (sobrescribir), salvo que se haya pedido -o- explícitamente
    if YesAll and not OverwriteGiven then Opt.Overwrite := owAll;
    // -ep al leer: como e (sin rutas); -ep1 solo tiene sentido al agregar (al leer, -ap)
    if (MO.EpMode = 0) and ((Cmd = 'x') or (Cmd = 'e')) then Opt.FlatNames := True;
    Opt.Filter := Filter;
    // stdin y stdout. Un archivo no se puede escribir de corrido (los descriptores apuntan
    // atrás) ni leer sin saber dónde termina (el footer va al final): se pasa por un temporal.
    // stdout lleva datos: los mensajes van a stderr.
    if Opt.ToStdout then OutToStderr := True;
    if (MO.StdinName <> '') and (Cmd <> 'a') then
    begin
      ErrLn('ERROR: -si is only valid with command a');
      Halt(1);
    end;
    if (MO.StdinName <> '') and (ArcName = '-') then
    begin
      ErrLn('ERROR: stdin cannot be both the archive and a file to add (-si with "-")');
      Halt(1);
    end;
    ToStdout := False;
    if ArcName = '-' then
    begin
      if WorkDir <> '' then S := WorkDir else S := GetTempDir;
      if (Cmd = 'l') or (Cmd = 'lb') or (Cmd = 't') or (Cmd = 'x') or (Cmd = 'e') or (Cmd = 'v') or
         (Cmd = 'lt') or (Cmd = 'cw') then
      begin
        ArcName := IncludeTrailingPathDelimiter(S) + Format('parc-stdin-%d.tmp', [GetProcessID]);
        RegisterTempFile(ArcName);
        StdinToFile(ArcName);
      end
      else if (Cmd = 'a') or (Cmd = 'create') then
      begin
        if MO.VolumeSize > 0 then
        begin
          ErrLn('ERROR: -v cannot be used with an archive on stdout ("-")');
          Halt(1);
        end;
        OutToStderr := True;
        ToStdout := True;
        MO.ShownName := '(standard output)';
        ArcName := IncludeTrailingPathDelimiter(S) + Format('parc-stdout-%d', [GetProcessID]) + '.parc';
        RegisterTempFile(ArcName);
      end
      else
      begin
        ErrLn('ERROR: "-" (stdin/stdout) sirve con l, lb, t, x, e y a');
        Halt(1);
      end;
    end;
    if MO.StdinName <> '' then
    begin
      // al lado del archivo (o en -w): el tamaño tiene que conocerse antes de comprimir (el
      // diccionario se ajusta a él), y en el disco del archivo seguro que hay lugar
      if WorkDir <> '' then S := IncludeTrailingPathDelimiter(ExpandFileName(WorkDir))
      else S := ExtractFilePath(ExpandFileName(ArcName));
      MO.StdinFile := S + Format('.parc-stdin-%d.tmp', [GetProcessID]);
      RegisterTempFile(MO.StdinFile);
      StdinToFile(MO.StdinFile);
    end;
    // "x.parc.001" es lo mismo que "x.parc" (el primero de sus volúmenes)
    if IsVolumeSet(ArcName, S) then ArcName := S;
    // -kf: el contenido del archivo clave entra en la contraseña (FORMATO-PARC.md §3b)
    if KeyFile <> '' then
      try
        KeyDigest := KeyFileDigest(KeyFile);
      except
        on E: Exception do begin ErrLn('ERROR: ' + E.Message); Halt(4); end;
      end;
    // -p- / -hp-: sin contraseña (ch: quitar el cifrado)
    if DPwd = '-' then begin DPwd := '--'; NoDataPwd := True; end;
    if HPwd = '-' then begin HPwd := '--'; NoHeadPwd := True; end;
    // ch con alguna opción de contraseña: el cifrado se rehace entero con lo que se dio
    PwdOpt := (DPwd <> '--') or (HPwd <> '--') or NoDataPwd or NoHeadPwd or (KeyFile <> '');
    if BaseCmd = 'ch' then
    begin
      MO.NoDataPwd := NoDataPwd;
      MO.NoHeadPwd := NoHeadPwd or NoDataPwd;
    end;
    // Contraseñas como Cmdline.hs: -p solo cifra datos; -hp (con o sin -p) cifra también
    // los encabezados; -p y -hp con valores distintos, uno para cada cosa
    if HPwd <> '--' then
    begin
      if HPwd = '' then HPwd := DPwd;
      if DPwd = '--' then DPwd := HPwd
      else if DPwd = '' then DPwd := HPwd;
    end;
    if Writing and ((DPwd = '') or (HPwd = '')) then
    begin
      // -p / -hp sin valor al comprimir: pedirla dos veces (un error de tipeo no tiene arreglo)
      if not ReadPassword('Password for encryption: ', S) or (S = '') then
      begin
        ErrLn('ERROR: a password is required (no console to prompt)');
        Halt(1);
      end;
      if not ReadPassword('Repeat it: ', Pwd2) or (Pwd2 <> S) then
      begin
        ErrLn('ERROR: passwords do not match');
        Halt(1);
      end;
      if DPwd = '' then DPwd := S;
      if HPwd = '' then HPwd := S;
    end;
    // -kf solo (sin -p): el archivo clave es la contraseña de los datos; con -p/-hp se mezcla
    // con cada una. Al leer, un -p sin valor se pide por consola y se mezcla al pedirla.
    if KeyDigest <> '' then
      if (DPwd = '--') and (HPwd = '--') then DPwd := MixKeyFile('', KeyDigest)
      else
      begin
        if (DPwd <> '--') and (DPwd <> '') then DPwd := MixKeyFile(DPwd, KeyDigest);
        if (HPwd <> '--') and (HPwd <> '') then HPwd := MixKeyFile(HPwd, KeyDigest);
      end;
    if (DPwd <> '--') and (DPwd <> '') then MO.DataPassword := DPwd;
    if (HPwd <> '--') and (HPwd <> '') then MO.HeadersPassword := HPwd;
    if Writing and not ParseCipherChoice(MO.Encryption, Cipher) then
    begin
      ErrLn('ERROR: invalid encryption algorithm "' + MO.Encryption + '" (chacha or aes, ' +
            'optionally with :t<passes>:m<KiB, or n m/g>:p<lanes>)');
      Halt(1);
    end;
    // La principal es la de los datos (con esa se vuelve a cifrar lo que se reempaqueta);
    // la de encabezados, si es otra, se prueba también (-p y -hp distintas)
    if MO.DataPassword <> '' then SetArchivePassword(MO.DataPassword);
    if (MO.HeadersPassword <> '') and (MO.HeadersPassword <> MO.DataPassword) then
      AddArchivePassword(MO.HeadersPassword);
    // -op: la contraseña vieja, solo para leer (ch al cambiar o quitar el cifrado)
    if OldPwd <> '' then AddArchivePassword(OldPwd);


    if ShowProgress and ErrIsConsole then ProgressHandler := @DrawProgress;
    InstallCancelHandler(@OnCtrlC);
    if Cmd = 'r' then
    begin
      // Antes de abrir el archivo: dañado puede no abrir normalmente
      try
        Code := CmdRepair(ArcName);
      except
        on E: Exception do begin ErrLn('ERROR: ' + E.Message); Code := 4; end;
      end;
      Halt(Code);
    end;
    if Writing then
    begin
      // -tp: probar el archivo que se va a modificar; si falla, no se toca
      if PreTest and ArchiveExists(ArcName) then
      begin
        Code := TestArchiveFile(ArcName, Opt);
        if Code <> 0 then
        begin
          ErrLn('ERROR: the archive failed the test before the operation (-tp): ' + ArcName + ' was not modified');
          Halt(Code);
        end;
      end;
      Tries := 0;
      repeat
      Retry := False;
      try
        Code := CmdModify(BaseCmd, ArcName, Filter, MO);
        // -t: probar el archivo recién escrito; el código de salida es el del test si falla
        if TestAfter and ((Code = 0) or (Code = EXIT_WARNINGS)) then
        begin
          TestFlipHook(ArcName);
          TCode := TestArchiveFile(ArcName, Opt);
          if TCode <> 0 then
          begin
            ErrLn('ERROR: the new archive failed the test (-t)');
            Code := TCode;
          end;
        end;
        if ToStdout and ((Code = 0) or (Code = EXIT_WARNINGS)) then FileToStdout(ArcName);
        // m/mf/-d/-df: solo con todo bien (escrito y, con -t, probado)
        if (MO.MoveMode > 0) and (Code = 0) and (DeleteMoved(MO.MoveMode) > 0) then Code := EXIT_WARNINGS;
      except
        // El archivo viejo está cifrado y no se dio -p: pedirla, como en x/t
        on E: EPasswordRequired do
          if (Tries < 3) and ReadPassword('Password: ', S) then
          begin
            AddPromptedPassword(S);
            Inc(Tries);
            Retry := True;
          end
          else begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EBadPassword do
          if (Tries < 3) and ReadPassword('Wrong password. Password: ', S) then
          begin
            AddPromptedPassword(S);
            Inc(Tries);
            Retry := True;
          end
          else begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EOperationCancelled do begin
          ClearProgress;
          if FileExists(FsPath(ArcName)) then ErrLn('Cancelled: ' + ArcName + ' was left unchanged.')
          else ErrLn('Cancelled: ' + ArcName + ' was not created.');
          Code := EXIT_CANCELLED;
        end;
        on E: EUnsupportedEncoder do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 3; end;
        on E: EFOpenError do
        begin ClearProgress; ErrLn('ERROR: ' + FileErrorText(E.Message, True)); Code := 4; end;
        on E: EFCreateError do
        begin ClearProgress; ErrLn('ERROR: ' + FileErrorText(E.Message, False)); Code := 4; end;
        on E: Exception do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 4; end;
      end;
      until not Retry;
      Halt(Code);
    end;
    Tries := 0;
    repeat
      Retry := False;
      try
        A := TArchive.Open(ArcName);
        try
          if Cmd = 'lb' then CmdBlocks(A)
          else if Cmd = 'lt' then CmdTechList(A)
          else if Cmd = 'cw' then
          begin
            // cw <archivo> <destino>: el comentario a un archivo, o a stdout con "-"
            if Filter.Count <> 1 then Fail('cw needs one output file name (or "-" for stdout)');
            if Filter[0] = '-' then
            begin
              F := nil;
              if A.Comment <> '' then
                with THandleStream.Create(StdoutHandle) do
                  try WriteBuffer(A.Comment[1], Length(A.Comment)); finally Free; end;
            end
            else
            begin
              F := TFileStream.Create(FsPath(Filter[0]), fmCreate);
              try
                if A.Comment <> '' then F.WriteBuffer(A.Comment[1], Length(A.Comment));
              finally
                F.Free;
              end;
            end;
          end
          else
          begin
            // Selección (patrones, -n, -x, -sm/-sl, -t*, --dirs/-ed, -ap); con -ap los nombres
            // quedan relativos a ese directorio
            MO.Sel.Patterns := Filter;
            Sel := SelectArchive(A, MO.Sel);
            if MO.Sel.ArcPath <> '' then
              for i := 0 to High(A.Files) do
                if Sel[i] and UnderArcPath(MO.Sel, A.Files[i].Name, Rel) then A.Files[i].Name := Rel;
            Opt.Sel := Sel;
            if Cmd = 'v' then CmdListVerbose(A, Sel)
            else if Cmd = 'l' then
            begin
              if (Filter.Count = 0) and (MO.Sel.ArcPath = '') and not ContentFilters(MO.Sel)
                 and (Excludes.Count = 0) and (MO.Sel.Dirs = dmAuto) then CmdList(A, [])
              else CmdList(A, Sel);
            end
            else if (Cmd = 't') or (Cmd = 'x') or (Cmd = 'e') then Code := CmdExtract(A, Cmd, Opt)
            else
            begin
              Usage;
              Code := 1;
            end;
          end;
        finally
          A.Free;
        end;
      except
        on E: EPasswordRequired do
          // Sin -p: pedirla por consola (hasta 3 intentos), como FreeArc
          if (Tries < 3) and ReadPassword('Password: ', S) then
          begin
            AddPromptedPassword(S);
            Inc(Tries);
            Retry := True;
          end
          else begin ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EBadPassword do
          if (Tries > 0) and (Tries < 3) and ReadPassword('Wrong password. Password: ', S) then
          begin
            AddPromptedPassword(S);
            Inc(Tries);
            Retry := True;
          end
          else begin ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EOperationCancelled do begin ClearProgress; ErrLn('Cancelled.'); Code := EXIT_CANCELLED; end;
        on E: EArcCorrupt do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 2; end;
        on E: EUnsupportedMethod do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 3; end;
        on E: EFOpenError do
        begin ClearProgress; ErrLn('ERROR: ' + FileErrorText(E.Message, True)); Code := 4; end;
        on E: EFCreateError do
        begin ClearProgress; ErrLn('ERROR: ' + FileErrorText(E.Message, False)); Code := 4; end;
        on E: Exception do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 4; end;
      end;
    until not Retry;
  finally
    Filter.Free;
    Excludes.Free;
    Includes.Free;
    McOps.Free;
  end;
  Halt(Code);
end.
