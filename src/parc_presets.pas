{ Compression presets (-m0..-m9, -mx, -mxx, -m5x, -mex5, -m5d, -m5t, ...) and file groups.

  PArc's own design (2026-11): a table of preset rows plus a small resolver.

  Preset rows (PRESETS below). Each row is
      name   levels   group   chain   [threads: chain]
  - name: a plain name ('bmp', 'xlzma', 'x') or a level family with 'N' where the level digit
    goes ('Nbinary', 'exNt', 'N', 'Nx'). A family row covers levels Lo..Hi (1..9); 'N' inside
    the chain is replaced by the level digit, so rows can refer to other families of the same
    level ('Norep+exe+Nxb').
  - group: '' is the default chain of the name; '$text', '$obj', ... add a chain for that file
    group. All rows of one name and level, in table order, make its group list. A name with
    group rows is a "preset": used as the whole -m (or as a whole $group= chain) it brings its
    groups; used as one stage of a longer chain only its default chain is used.
  - threads: with at least MtAt threads (PARC_THREADS / -mt) MtChain replaces the chain
    (the multi-threaded variants: 4x4 blocks, bwt with its own threads...).
  - An empty group chain removes that group (its files go with the default chain).

  Resolving -m<text>:
  - "(a|b)name" and "a|b|c" pick one alternative by thread count (the k-th for k threads, the
    last one beyond; an empty one repeats the previous one), as FreeArc's syntax;
  - "chain/$group=chain/..." sets or removes per-group chains (a later one replaces an earlier
    one and goes last); "bin/text" (second part without '$') is "exe+bin / $obj=bin / $text=text";
  - every stage name is looked up in the table (recursively); "name:params" appends the params
    to the chain it resolves to ("xlzma:64m" -> "4x4:lzma:64m"); "P$group" is the chain of
    preset P for that group ("5$wav" -> "tta"); unknown names are codec stages and stay as they
    are (the encoder reports what it does not know).

  File groups (FILE_GROUPS below): each group lists its name masks ("*.ext", or a glob on the
  base name: "readme.*", "*.??_"); "<other>" marks where files that match no mask are sorted. A
  file belongs to every group with a matching mask; the sort rank is the position of the first
  matching mask in the whole table. }
unit parc_presets;

{$mode objfpc}{$H+}
{$J-}   // the tables are constants

interface

uses
  SysUtils;

type
  TGroupMethod = record
    Group: string;     // '' = default; else '$text', '$obj', '$wav', ...
    Method: string;    // stages joined with '+'
  end;
  TGroupMethods = array of TGroupMethod;

{ -m text -> chains per group, default first (when there is one). Cpus picks the multi-threaded
  variants. Never raises: what cannot be resolved stays as text for the encoder to reject. }
function DecodeMethod(const Str: string; Cpus: Integer): TGroupMethods;

{ The chain for Group, or the default one. }
function MethodForGroup(const GM: TGroupMethods; const Group: string): string;

{ File groups in table order ('$text', '$binary', ...). }
function FileGroupNames: TStringArray;
{ Bit g set: the file Name (stored name, '/' separators) matches a mask of group g. }
function FileGroupMatches(const Name: string): QWord;
{ Sort rank of Name: position of its first matching mask (the "<other>" position if none). }
function FileGroupRank(const Name: string): Integer;
{ Ranks go from 0 to FileGroupRankCount - 1. }
function FileGroupRankCount: Integer;

{ The tables as text (--print-config). }
function PresetTableLines: TStringArray;
function FileGroupLines: TStringArray;

implementation

uses
  parc_strmap;

type
  TPresetRow = record
    Name: string;
    Lo, Hi: Byte;        // 0, 0 for plain names
    Group: string;
    Chain: string;
    MtAt: Byte;          // 0 = no multi-threaded variant
    MtChain: string;
  end;

const
  { Method choices are PArc's tuning (see docs/ESTADO.md, "Presets"). }
  PRESETS: array[0..116] of TPresetRow = (
    // --- building blocks: one chain per level ---------------------------------------------
    // fast-decompressing LZ back ends
    (Name: 'Nbinary'; Lo: 1; Hi: 1; Group: ''; Chain: 'plz:2'; MtAt: 2; MtChain: 'exNbinary'),
    (Name: 'Nbinary'; Lo: 2; Hi: 2; Group: ''; Chain: 'plz:4'; MtAt: 2; MtChain: 'exNbinary'),
    (Name: 'Nbinary'; Lo: 3; Hi: 3; Group: ''; Chain: 'lzma:96m:fast:32:mc6:lc4'; MtAt: 2; MtChain: 'exNbinary'),
    (Name: 'Nbinary'; Lo: 4; Hi: 4; Group: ''; Chain: 'lzma:96m:normal:16:mc8:lc4'; MtAt: 3; MtChain: 'exNbinary'),
    (Name: 'Nbinary'; Lo: 5; Hi: 5; Group: ''; Chain: 'lzma:96m:normal:32:bt4:mc8:lc4:pb1'; MtAt: 3; MtChain: 'exNbinary'),
    (Name: 'Nbinary'; Lo: 6; Hi: 6; Group: ''; Chain: 'lzma:32m:max'; MtAt: 0; MtChain: ''),
    (Name: 'Nbinary'; Lo: 7; Hi: 7; Group: ''; Chain: 'lzma:64m:max'; MtAt: 0; MtChain: ''),
    (Name: 'Nbinary'; Lo: 8; Hi: 8; Group: ''; Chain: 'lzma:128m:max'; MtAt: 0; MtChain: ''),
    (Name: 'Nbinary'; Lo: 9; Hi: 9; Group: ''; Chain: 'lzma:254m:max'; MtAt: 0; MtChain: ''),
    // the same in independent blocks (4x4), for several threads
    (Name: 'exNbinary'; Lo: 1; Hi: 1; Group: ''; Chain: '4x4:plz:1'; MtAt: 0; MtChain: ''),
    (Name: 'exNbinary'; Lo: 2; Hi: 2; Group: ''; Chain: '4x4:plz:3'; MtAt: 0; MtChain: ''),
    (Name: 'exNbinary'; Lo: 3; Hi: 3; Group: ''; Chain: '4x4:lzma:16mb:normal:16:mc4:lc4'; MtAt: 0; MtChain: ''),
    (Name: 'exNbinary'; Lo: 4; Hi: 4; Group: ''; Chain: '4x4:lzma:24mb:normal:20:mc6:lc5:pb1'; MtAt: 0; MtChain: ''),
    (Name: 'exNbinary'; Lo: 5; Hi: 5; Group: ''; Chain: '4x4:lzma:24mb:normal:32:bt4:mc8:lc4'; MtAt: 0; MtChain: ''),
    (Name: 'exNbinary'; Lo: 6; Hi: 6; Group: ''; Chain: '4x4:i0:lzma:8mb:max'; MtAt: 0; MtChain: ''),
    (Name: 'exNbinary'; Lo: 7; Hi: 7; Group: ''; Chain: '4x4:i0:lzma:16mb:max'; MtAt: 0; MtChain: ''),
    (Name: 'exNbinary'; Lo: 8; Hi: 8; Group: ''; Chain: '4x4:i0:lzma:32mb:max'; MtAt: 0; MtChain: ''),
    (Name: 'exNbinary'; Lo: 9; Hi: 9; Group: ''; Chain: '4x4:i0:lzma:64mb:max'; MtAt: 0; MtChain: ''),
    // long-range matches in front of everything
    (Name: 'Norep'; Lo: 1; Hi: 1; Group: ''; Chain: 'orep:96m:l256:c2:r512'; MtAt: 0; MtChain: ''),
    (Name: 'Norep'; Lo: 2; Hi: 2; Group: ''; Chain: 'orep:96m:l256:r512'; MtAt: 0; MtChain: ''),
    (Name: 'Norep'; Lo: 3; Hi: 5; Group: ''; Chain: 'orep:96m:l512'; MtAt: 0; MtChain: ''),
    (Name: 'Norep'; Lo: 6; Hi: 6; Group: ''; Chain: 'orep:256m:l512'; MtAt: 0; MtChain: ''),
    (Name: 'Norep'; Lo: 7; Hi: 7; Group: ''; Chain: 'orep:512m:l512'; MtAt: 0; MtChain: ''),
    (Name: 'Norep'; Lo: 8; Hi: 8; Group: ''; Chain: 'orep:1024m:l512'; MtAt: 0; MtChain: ''),
    (Name: 'Norep'; Lo: 9; Hi: 9; Group: ''; Chain: 'orep:2040m:l512'; MtAt: 0; MtChain: ''),
    // binary data, fast decompression: table filter + LZ
    (Name: 'Nxb'; Lo: 1; Hi: 1; Group: ''; Chain: 'Nbinary'; MtAt: 0; MtChain: ''),
    (Name: 'Nxb'; Lo: 2; Hi: 2; Group: ''; Chain: 'delta+Nbinary'; MtAt: 2; MtChain: 'Nbinary'),
    (Name: 'Nxb'; Lo: 3; Hi: 9; Group: ''; Chain: 'delta+Nbinary'; MtAt: 0; MtChain: ''),
    (Name: 'Nbx'; Lo: 1; Hi: 9; Group: ''; Chain: 'Nxb'; MtAt: 0; MtChain: ''),
    (Name: 'Nb'; Lo: 1; Hi: 9; Group: ''; Chain: 'Norep+Nxb'; MtAt: 0; MtChain: ''),
    (Name: 'exNb'; Lo: 1; Hi: 2; Group: ''; Chain: 'exNbinary'; MtAt: 0; MtChain: ''),
    (Name: 'exNb'; Lo: 3; Hi: 9; Group: ''; Chain: 'delta+exNbinary'; MtAt: 0; MtChain: ''),
    // text, fast decompression
    (Name: 'Nxt'; Lo: 1; Hi: 2; Group: ''; Chain: 'Nxb'; MtAt: 0; MtChain: ''),
    (Name: 'Nxt'; Lo: 3; Hi: 3; Group: ''; Chain: 'dict:64m:80%+plz:5:96m'; MtAt: 0; MtChain: ''),
    (Name: 'Nxt'; Lo: 4; Hi: 4; Group: ''; Chain: 'dict:64m:75%+Nbinary'; MtAt: 0; MtChain: ''),
    (Name: 'Nxt'; Lo: 5; Hi: 9; Group: ''; Chain: 'dict:128m:75%+Nbinary'; MtAt: 0; MtChain: ''),
    (Name: 'Ntx'; Lo: 1; Hi: 9; Group: ''; Chain: 'Nxt'; MtAt: 0; MtChain: ''),
    // text, best ratio (slower decompression)
    (Name: 'Nt'; Lo: 1; Hi: 1; Group: ''; Chain: 'Nb'; MtAt: 0; MtChain: ''),
    (Name: 'Nt'; Lo: 2; Hi: 2; Group: ''; Chain: 'bwt:m4:8m:32:h18:a:e1'; MtAt: 2; MtChain: 'exNt'),
    (Name: 'Nt'; Lo: 3; Hi: 3; Group: ''; Chain: 'dict:p:64m:85%+bwt:m1:8m:32:h20:a'; MtAt: 2; MtChain: 'exNt'),
    (Name: 'Nt'; Lo: 4; Hi: 4; Group: ''; Chain: 'dict:p:64m:80%+lzp:64m:65:d1m:s16:h20:90%+ppmd:8:192m'; MtAt: 2; MtChain: 'exNt'),
    (Name: 'Nt'; Lo: 5; Hi: 5; Group: ''; Chain: 'dict:p:64m:80%+lzp:80m:105:d1m:s32:h22:92%+ppmd:13:192m'; MtAt: 2; MtChain: 'exNt'),
    (Name: 'Nt'; Lo: 6; Hi: 9; Group: ''; Chain: 'dict:p:128m:75%:l8192:m800:s250+lzp:160m:145:d1m:s32:h23:90%+ppmd:18:512m'; MtAt: 0; MtChain: ''),
    (Name: 'exNt'; Lo: 1; Hi: 1; Group: ''; Chain: 'exNb'; MtAt: 0; MtChain: ''),
    (Name: 'exNt'; Lo: 2; Hi: 2; Group: ''; Chain: 'bwt:m4:h20:a:e1'; MtAt: 0; MtChain: ''),
    (Name: 'exNt'; Lo: 3; Hi: 3; Group: ''; Chain: 'bwt:m2:h20:a'; MtAt: 0; MtChain: ''),
    (Name: 'exNt'; Lo: 4; Hi: 4; Group: ''; Chain: 'bwt:m1:h20:a'; MtAt: 0; MtChain: ''),
    (Name: 'exNt'; Lo: 5; Hi: 5; Group: ''; Chain: 'dict:p:64m:80%+lzp:64m:65:d1m:s32:h22:90%+xppmd:12:192m'; MtAt: 0; MtChain: ''),
    (Name: 'exNt'; Lo: 6; Hi: 6; Group: ''; Chain: 'dict:p:64m:80%+lzp:80m:105:d1m:s32:h22:92%+xppmd:12:192m'; MtAt: 0; MtChain: ''),
    (Name: 'exNt'; Lo: 7; Hi: 9; Group: ''; Chain: 'dict:p:128m:80%+lzp:160m:145:d1m:s32:h23:92%+xppmd:18:512m'; MtAt: 0; MtChain: ''),

    // --- presets (with file groups) -----------------------------------------------------------
    // -m1..-m9
    (Name: 'N'; Lo: 1; Hi: 1; Group: ''; Chain: 'Nb'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 2; Hi: 9; Group: ''; Chain: 'Norep+exe+Nxb'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 2; Hi: 9; Group: '$obj'; Chain: 'Nb'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 2; Hi: 9; Group: '$text'; Chain: 'Nt'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 2; Hi: 2; Group: '$wav'; Chain: 'wavfast'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 2; Hi: 2; Group: '$bmp'; Chain: 'bmpfastest'; MtAt: 2; MtChain: 'bmpfast'),
    (Name: 'N'; Lo: 2; Hi: 2; Group: '$compressed'; Chain: '2orep+1binary'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 3; Hi: 3; Group: '$bmp'; Chain: 'bmpfast'; MtAt: 2; MtChain: 'bmp'),
    (Name: 'N'; Lo: 3; Hi: 3; Group: '$compressed'; Chain: '3orep+1binary'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 3; Hi: 3; Group: '$wav'; Chain: 'wav'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 4; Hi: 4; Group: '$compressed'; Chain: '4orep+eplz:3'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 4; Hi: 9; Group: '$wav'; Chain: 'wav'; MtAt: 0; MtChain: ''),
    (Name: 'N'; Lo: 4; Hi: 9; Group: '$bmp'; Chain: 'bmp'; MtAt: 0; MtChain: ''),
    // -m1x..-m9x: fast decompression (no orep, no ppmd/bwt)
    (Name: 'Nx'; Lo: 1; Hi: 1; Group: ''; Chain: 'N'; MtAt: 0; MtChain: ''),
    (Name: 'Nx'; Lo: 2; Hi: 9; Group: ''; Chain: 'exe+Nxb'; MtAt: 0; MtChain: ''),
    (Name: 'Nx'; Lo: 2; Hi: 9; Group: '$obj'; Chain: 'Nxb'; MtAt: 0; MtChain: ''),
    (Name: 'Nx'; Lo: 2; Hi: 9; Group: '$text'; Chain: 'Nxt'; MtAt: 0; MtChain: ''),
    (Name: 'Nx'; Lo: 1; Hi: 2; Group: '$bmp'; Chain: 'bmpfastest'; MtAt: 0; MtChain: ''),
    (Name: 'Nx'; Lo: 1; Hi: 1; Group: '$compressed'; Chain: 'storing'; MtAt: 2; MtChain: '1orep'),
    (Name: 'Nx'; Lo: 2; Hi: 3; Group: '$compressed'; Chain: 'Norep:8m+1binary'; MtAt: 0; MtChain: ''),
    (Name: 'Nx'; Lo: 4; Hi: 4; Group: '$compressed'; Chain: 'eplz:3:8m'; MtAt: 0; MtChain: ''),
    (Name: 'Nx'; Lo: 1; Hi: 9; Group: '$wav'; Chain: 'wavfast'; MtAt: 0; MtChain: ''),
    (Name: 'Nx'; Lo: 3; Hi: 9; Group: '$bmp'; Chain: 'mm+Nbinary'; MtAt: 0; MtChain: ''),
    (Name: 'xN'; Lo: 1; Hi: 9; Group: ''; Chain: 'Nx'; MtAt: 0; MtChain: ''),
    // -m1d..-m9d: fast but memory-hungry decompression
    (Name: 'Nd'; Lo: 1; Hi: 9; Group: ''; Chain: 'Norep+exe+Nxb'; MtAt: 0; MtChain: ''),
    (Name: 'Nd'; Lo: 1; Hi: 9; Group: '$obj'; Chain: 'Nb'; MtAt: 0; MtChain: ''),
    (Name: 'Nd'; Lo: 1; Hi: 9; Group: '$text'; Chain: 'dict+Nb'; MtAt: 0; MtChain: ''),
    (Name: 'Nd'; Lo: 1; Hi: 9; Group: '$compressed'; Chain: 'N$compressed'; MtAt: 0; MtChain: ''),
    (Name: 'Nd'; Lo: 1; Hi: 9; Group: '$wav'; Chain: 'Nx$wav'; MtAt: 0; MtChain: ''),
    (Name: 'Nd'; Lo: 1; Hi: 9; Group: '$bmp'; Chain: 'Nx$bmp'; MtAt: 0; MtChain: ''),
    // -mex1..-mex9: every chain multi-threaded
    (Name: 'exN'; Lo: 1; Hi: 1; Group: ''; Chain: 'exNb'; MtAt: 0; MtChain: ''),
    (Name: 'exN'; Lo: 1; Hi: 1; Group: '$wav'; Chain: 'mm:d1+exNb'; MtAt: 0; MtChain: ''),
    (Name: 'exN'; Lo: 1; Hi: 1; Group: '$bmp'; Chain: 'mm:d1+exNb'; MtAt: 0; MtChain: ''),
    (Name: 'exN'; Lo: 2; Hi: 9; Group: ''; Chain: 'Norep+exe+exNb'; MtAt: 0; MtChain: ''),
    (Name: 'exN'; Lo: 2; Hi: 9; Group: '$obj'; Chain: 'Norep+exNb'; MtAt: 0; MtChain: ''),
    (Name: 'exN'; Lo: 2; Hi: 9; Group: '$text'; Chain: 'exNt'; MtAt: 0; MtChain: ''),
    (Name: 'exN'; Lo: 2; Hi: 9; Group: '$wav'; Chain: 'N$wav'; MtAt: 0; MtChain: ''),
    (Name: 'exN'; Lo: 2; Hi: 9; Group: '$bmp'; Chain: 'N$bmp'; MtAt: 0; MtChain: ''),
    (Name: 'exN'; Lo: 2; Hi: 9; Group: '$compressed'; Chain: 'N$compressed'; MtAt: 0; MtChain: ''),
    (Name: 'Nex'; Lo: 1; Hi: 9; Group: ''; Chain: 'exN'; MtAt: 0; MtChain: ''),
    // -m0, -mx, -mxx, -max
    (Name: '0'; Lo: 0; Hi: 0; Group: ''; Chain: 'storing'; MtAt: 0; MtChain: ''),
    (Name: 'x'; Lo: 0; Hi: 0; Group: ''; Chain: '9'; MtAt: 0; MtChain: ''),
    (Name: 'xx'; Lo: 0; Hi: 0; Group: ''; Chain: '9'; MtAt: 0; MtChain: ''),
    (Name: 'xx'; Lo: 0; Hi: 0; Group: '$text'; Chain: 'dict:p:128m:75%:l8192:m800:s250+lzp:160m:145:d1m:s32:h23:90%+cm'; MtAt: 0; MtChain: ''),
    (Name: 'xx'; Lo: 0; Hi: 0; Group: '$binary'; Chain: 'orep:64m:l512:a1+exe+delta+cm'; MtAt: 0; MtChain: ''),
    (Name: 'xx'; Lo: 0; Hi: 0; Group: '$obj'; Chain: 'orep:64m:l512:a1+exe+delta+cm'; MtAt: 0; MtChain: ''),
    (Name: 'ax'; Lo: 0; Hi: 0; Group: ''; Chain: '9p'; MtAt: 0; MtChain: ''),   // (external compressors: not available)

    // --- named chains and synonyms ---------------------------------------------------------
    (Name: 'wav'; Lo: 0; Hi: 0; Group: ''; Chain: 'tta'; MtAt: 0; MtChain: ''),
    (Name: 'wavfast'; Lo: 0; Hi: 0; Group: ''; Chain: 'tta:m1'; MtAt: 0; MtChain: ''),
    (Name: 'bmp'; Lo: 0; Hi: 0; Group: ''; Chain: 'mm+bwt:m1:l2048:a'; MtAt: 0; MtChain: ''),
    (Name: 'bmpfast'; Lo: 0; Hi: 0; Group: ''; Chain: 'mm+bwt:m4:l:a'; MtAt: 0; MtChain: ''),
    (Name: 'bmpfastest'; Lo: 0; Hi: 0; Group: ''; Chain: 'mm:d1+1binary'; MtAt: 0; MtChain: ''),
    (Name: 'xplz'; Lo: 0; Hi: 0; Group: ''; Chain: '4x4:plz'; MtAt: 0; MtChain: ''),
    (Name: 'xlzma'; Lo: 0; Hi: 0; Group: ''; Chain: '4x4:lzma'; MtAt: 0; MtChain: ''),
    (Name: 'xppmd'; Lo: 0; Hi: 0; Group: ''; Chain: '4x4:b7mb:ppmd'; MtAt: 0; MtChain: ''),
    (Name: 'xlz4'; Lo: 0; Hi: 0; Group: ''; Chain: '4x4:lz4'; MtAt: 0; MtChain: ''),
    (Name: 'lz4hc'; Lo: 0; Hi: 0; Group: ''; Chain: 'lz4:hc'; MtAt: 0; MtChain: ''),
    (Name: 'xlz4hc'; Lo: 0; Hi: 0; Group: ''; Chain: '4x4:lz4:hc'; MtAt: 0; MtChain: ''),
    (Name: 'eplz'; Lo: 0; Hi: 0; Group: ''; Chain: 'plz'; MtAt: 2; MtChain: 'xplz'),
    (Name: 'elzma'; Lo: 0; Hi: 0; Group: ''; Chain: 'lzma'; MtAt: 2; MtChain: 'xlzma'),
    (Name: 'eppmd'; Lo: 0; Hi: 0; Group: ''; Chain: 'ppmd'; MtAt: 2; MtChain: 'xppmd'),
    (Name: 'elz4'; Lo: 0; Hi: 0; Group: ''; Chain: 'lz4'; MtAt: 2; MtChain: 'xlz4'),
    (Name: 'elz4hc'; Lo: 0; Hi: 0; Group: ''; Chain: 'lz4hc'; MtAt: 2; MtChain: 'xlz4hc'),
    (Name: 'bcj'; Lo: 0; Hi: 0; Group: ''; Chain: 'exe'; MtAt: 0; MtChain: ''),
    (Name: 'copy'; Lo: 0; Hi: 0; Group: ''; Chain: 'storing'; MtAt: 0; MtChain: ''),
    (Name: 'exe2'; Lo: 0; Hi: 0; Group: ''; Chain: 'dispack'; MtAt: 0; MtChain: ''),
    (Name: 'dispack'; Lo: 0; Hi: 0; Group: ''; Chain: 'dispack070'; MtAt: 0; MtChain: '')
  );

type
  TFileGroupRow = record
    Name: string;
    Masks: string;   // separated by spaces; "<other>" = rank of the files that match nothing
  end;

const
  FILE_GROUPS: array[0..11] of TFileGroupRow = (
    (Name: '$text'; Masks:
      'file_id.diz descript.ion files.bbs read.me readme readme.* *. *.txt *.asc *.lng ' +
      '*.css *.dtd *.dtdxml *.htm *.html *.shtml *.xml *.xsl *.xsd *.docbook *.fo *.vcproj ' +
      '*.sgml *.yaml *.asp *.cgi *.rd *.1 *.man *.pod *.pl *.prl *.pm *.rex *.rb *.rbw *.py ' +
      '*.sed *.awk *.tcl *.lua *.mlua *.php *.m4 *.el *.elc *.vim *.sh *.ksh *.csh *.bash ' +
      '*.bat *.cmd *.btm *.bas *.vbs *.fpp *.for *.f *.ada *.adb *.ads *.lfm *.lpi *.lrs ' +
      '*.dfm *.pas *.src *.s *.asi *.inc *.asm *.xs *.y *.h *.hpp *.ipp *.hxx *.c *.cpp ' +
      '*.cxx *.c++ *.cc *.objc *.d *.cs *.java *.js *.hc *.gc *.hsc *.hs *.lhs *.mli *.ml ' +
      '*.hrl *.erl *.scm *.vi *.lst *.log *.ini *.cfg makefile makefile.* *.mak *.in *.dsp ' +
      '*.dsw *.rc *.idl *.~* *.bak *.tar *.sql *.pkt *.xbm *.xpm *.reg *.ps *.dvi *.tex ' +
      '*.txi *.texi *.texinfo *.info *.hlf *.eng *.rus *.cnt *.tbb *.tbi *.toc *.mbx *.csv ' +
      '*.rtf *.wrd *.wri'),
    (Name: '$binary'; Masks:
      '*.doc <other> *.hlp *.inf *.xls *.ppt *.mdb *.dbf'),
    (Name: '$exe'; Masks:
      '*.com *.exe *.scr *.sfx *.dll *.so *.ocx *.bpl *.dpl *.ovr *.ovl *.rtl *.386 *.vxd ' +
      '*.drv *.sys'),
    (Name: '$iso'; Masks:
      '*.iso *.nrg *.bin *.cue *.img *.mds *.mdf *.c2d *.ashdisc *.b5t *.b5i *.bwt *.bwi ' +
      '*.lcd *.ccd *.dvd *.000 *.cdi *.dao *.tao *.cif *.xmf *.xmd *.p01 *.md1 *.xa *.pdi ' +
      '*.dmg *.vaporcd *.ncd *.pxi *.rif *.rdf *.gcd *.gi *.ixa *.fc4 *.fcd *.vcd *.vdi ' +
      '*.ima *.bif'),
    (Name: '$obj'; Masks:
      '*.dcu *.obj *.o *.a *.lib'),
    (Name: '$bmp'; Masks:
      '*.bmp *.tif *.tiff *.tga *.wbm *.wbmp *.pgm *.pnm *.ppm'),
    (Name: '$wav'; Masks:
      '*.wav *.wave *.pcm *.aif *.aifc *.aiff *.au *.snd *.xac *.iff *.voc *.paf *.sd2'),
    (Name: '$mod'; Masks:
      '*.stm *.mod *.s3m *.it *.xm *.669 *.dmf *.gt2 *.mdl *.okt *.skm *.umx'),
    // ('.pak' only here: as $compressed it was stored uncompressed at -m1)
    (Name: '$precomp'; Masks:
      '*.pdf *.swf *.zip *.jar *.png *.gif *.gz *.tgz *.svgz *.sis *.gadget *.fb2z *.docx ' +
      '*.docm *.dotx *.dotm *.xlsx *.xlsm *.xltx *.xltm *.xlam *.pptx *.pptm *.potx *.potm ' +
      '*.ppam *.ppsx *.ppsm *.odt *.ott *.odm *.oth *.ods *.ots *.odg *.otg *.odp *.otp ' +
      '*.odf *.odb *.oxt *.sxw *.stw *.sxg *.sxc *.stc *.sxi *.sti *.sxd *.std *.sxm *.ear? ' +
      '*.war? *.itz *.xmz *.s3z *.mdz *.pak *.pk3 *.pk4 *.eaz *.age3scn *.scx *.xmb *.a2c ' +
      '*.acm *.ahm *.frame *.jaz *.sequence *.wd *.rfd *.rfh *.gtr *.lod *.ezd *.cmo *.nmo ' +
      '*.sue *.trc *.clz *.sga *.gsv'),
    (Name: '$jpg'; Masks: ''),
    (Name: '$jpgsolid'; Masks: '*.jpg *.jpeg'),
    (Name: '$compressed'; Masks:
      '*.mp3 *.pmd *.pmm *.pms *.bz *.bz2 *.??_ *.??$ *.zoo *.arc *.hyp *.lzh *.chz *.arj ' +
      '*.a0? *.lim *.ark *.hpk *.cab *.bsa *.bs2 *.bsn *.ain *.r0? *.rar *.uc2 *.ha *.ufa ' +
      '*.bix *.7z *.j *.uha *.ccm *.ccmx *.chm *.djvu')
  );

  MAX_DEPTH = 24;

var
  RowIndex: TStrIntMap;          // row name -> index of its first row (rows of a name are contiguous)

{ ------------------------------------------------------------------------------------------ }
{ Group lists                                                                                }
{ ------------------------------------------------------------------------------------------ }

function DefaultOf(const M: TGroupMethods): string;
var
  i: Integer;
begin
  for i := 0 to High(M) do
    if M[i].Group = '' then Exit(M[i].Method);
  Result := '';
end;

function ChainOf(const M: TGroupMethods; const Group: string): string;
var
  i: Integer;
begin
  for i := 0 to High(M) do
    if M[i].Group = Group then Exit(M[i].Method);
  Result := '';
end;

{ Group gets Chain: an earlier entry goes away and the new one goes last ('' = none). }
procedure SetGroup(var M: TGroupMethods; const Group, Chain: string);
var
  i, n: Integer;
begin
  n := 0;
  for i := 0 to High(M) do
    if M[i].Group <> Group then
    begin
      M[n] := M[i];
      Inc(n);
    end;
  SetLength(M, n);
  if Chain <> '' then
  begin
    SetLength(M, n + 1);
    M[n].Group := Group;
    M[n].Method := Chain;
  end;
end;

function Single(const Chain: string): TGroupMethods;
begin
  Result := nil;
  SetGroup(Result, '', Chain);
end;

{ ------------------------------------------------------------------------------------------ }
{ Resolver                                                                                   }
{ ------------------------------------------------------------------------------------------ }

{ k-th alternative for k threads (the last one beyond); an empty one repeats the one before. }
function PickAlternative(const Alts: TStringArray; Cpus: Integer): string;
var
  k: Integer;
begin
  if Length(Alts) = 0 then Exit('');
  k := Cpus;
  if k > Length(Alts) then k := Length(Alts);
  if k < 1 then k := 1;
  Dec(k);
  while (k > 0) and (Alts[k] = '') do Dec(k);
  Result := Alts[k];
end;

{ "(a|b)rest" and "a|b|c" (user text). }
function ChooseAlternatives(const S: string; Cpus: Integer): string;
var
  p: Integer;
begin
  Result := S;
  if (Result <> '') and (Result[1] = '(') then
  begin
    p := Pos(')', Result);
    if p > 0 then
      Result := PickAlternative(Copy(Result, 2, p - 2).Split(['|']), Cpus) + Copy(Result, p + 1, MaxInt);
  end;
  if Pos('|', Result) > 0 then
    Result := PickAlternative(Result.Split(['|']), Cpus);
end;

{ Rows of Name: First..Last and the level (0 for plain names). False if it is not a table name. }
function FindName(const Name: string; out First, Last, Level: Integer): Boolean;
var
  i: Integer;
  Key: string;
begin
  Result := False;
  Level := 0;
  if (Name = '') or (Pos('N', Name) > 0) then Exit;
  First := RowIndex.Get(Name);
  if (First >= 0) and (PRESETS[First].Lo = 0) then
    Result := True
  else
  begin
    // a level family: one digit 1..9 replaced by 'N'
    First := -1;
    for i := 1 to Length(Name) do
      if Name[i] in ['1'..'9'] then
      begin
        Key := Copy(Name, 1, i - 1) + 'N' + Copy(Name, i + 1, MaxInt);
        First := RowIndex.Get(Key);
        if (First >= 0) and (PRESETS[First].Lo > 0) then
        begin
          Level := Ord(Name[i]) - Ord('0');
          Break;
        end;
        First := -1;
      end;
    if First < 0 then Exit;
    Result := True;
  end;
  Last := First;
  while (Last < High(PRESETS)) and (PRESETS[Last + 1].Name = PRESETS[First].Name) do Inc(Last);
end;

function ResolveChain(const Chain: string; Cpus, Depth: Integer): TGroupMethods; forward;

{ Is the name of rows First..Last a preset (has group rows, or is an alias of one)? }
function HasGroupRows(First, Last: Integer): Boolean;
var
  r: Integer;
begin
  for r := First to Last do
    if PRESETS[r].Group <> '' then Exit(True);
  // 'x' = '9'
  Result := (First = Last) and (PRESETS[First].Lo = 0) and (Length(PRESETS[First].Chain) = 1) and
    (PRESETS[First].Chain[1] in ['1'..'9']);
end;

function ChainDefault(const Chain: string; Cpus, Depth: Integer): string;
begin
  Result := DefaultOf(ResolveChain(Chain, Cpus, Depth));
end;

{ One stage: "name[:params]". }
function ResolveStage(const Stage: string; Cpus, Depth: Integer): TGroupMethods;
var
  Name, Params, Chain: string;
  p, First, Last, Level, r: Integer;
  HasDefault: Boolean;
  Row: ^TPresetRow;
begin
  if Depth > MAX_DEPTH then Exit(Single(Stage));
  p := Pos(':', Stage);
  if p > 0 then
  begin
    Name := Copy(Stage, 1, p - 1);
    Params := Copy(Stage, p, MaxInt);    // with the ':'
  end
  else
  begin
    Name := Stage;
    Params := '';
  end;
  // "P$group": that group's chain of preset P
  p := Pos('$', Name);
  if (p > 1) and FindName(Copy(Name, 1, p - 1), First, Last, Level) and HasGroupRows(First, Last) then
  begin
    Chain := ChainOf(ResolveStage(Copy(Name, 1, p - 1), Cpus, Depth + 1), Copy(Name, p, MaxInt));
    if (Chain <> '') and (Params <> '') then Chain := ChainDefault(Chain + Params, Cpus, Depth + 1);
    Exit(Single(Chain));
  end;
  if not FindName(Name, First, Last, Level) then Exit(Single(Stage));
  Result := nil;
  HasDefault := False;
  for r := First to Last do
  begin
    Row := @PRESETS[r];
    if (Level < Row^.Lo) or (Level > Row^.Hi) then Continue;
    if (Row^.MtAt > 0) and (Cpus >= Row^.MtAt) then Chain := Row^.MtChain else Chain := Row^.Chain;
    if Level > 0 then Chain := StringReplace(Chain, 'N', Chr(Ord('0') + Level), [rfReplaceAll]);
    if Row^.Group = '' then
    begin
      // the default row comes first: a whole preset as its chain brings its groups
      HasDefault := True;
      Result := ResolveChain(Chain + Params, Cpus, Depth + 1);
    end
    else
      SetGroup(Result, Row^.Group, ChainDefault(Chain, Cpus, Depth + 1));
  end;
  if not HasDefault and (Result = nil) then Result := Single('');
end;

{ "a+b+c": one stage gives all of its groups; several give their default chains joined. }
function ResolveChain(const Chain: string; Cpus, Depth: Integer): TGroupMethods;
var
  Stages: TStringArray;
  St, S, Joined: string;
  n: Integer;
begin
  Stages := Chain.Split(['+']);
  n := 0;
  for St in Stages do
    if St <> '' then Inc(n);
  if n = 1 then
  begin
    for St in Stages do
      if St <> '' then Exit(ResolveStage(St, Cpus, Depth));
  end;
  Joined := '';
  for St in Stages do
    if St <> '' then
    begin
      S := DefaultOf(ResolveStage(St, Cpus, Depth));
      if S = '' then Continue;
      if Joined <> '' then Joined := Joined + '+';
      Joined := Joined + S;
    end;
  Result := Single(Joined);
end;

function DecodeMethod(const Str: string; Cpus: Integer): TGroupMethods;
var
  Parts: TStringArray;
  S, Bin: string;
  i, p, From: Integer;
begin
  if Cpus < 1 then Cpus := 1;
  S := ChooseAlternatives(Str, Cpus);
  Parts := S.Split(['/']);
  if Length(Parts) = 0 then Exit(nil);
  Result := ResolveChain(Parts[0], Cpus, 0);
  From := 1;
  if (Length(Parts) > 1) and ((Parts[1] = '') or (Parts[1][1] <> '$')) then
  begin
    // "bin/text"
    Bin := DefaultOf(Result);
    Result := nil;
    if Bin <> '' then SetGroup(Result, '', 'exe+' + Bin) else SetGroup(Result, '', 'exe');
    SetGroup(Result, '$obj', Bin);
    SetGroup(Result, '$text', ChainDefault(Parts[1], Cpus, 0));
    From := 2;
  end;
  for i := From to High(Parts) do
  begin
    p := Pos('=', Parts[i]);
    if (Parts[i] = '') or (Parts[i][1] <> '$') or (p = 0) then Continue;
    SetGroup(Result, Copy(Parts[i], 1, p - 1), ChainDefault(Copy(Parts[i], p + 1, MaxInt), Cpus, 0));
  end;
end;

function MethodForGroup(const GM: TGroupMethods; const Group: string): string;
begin
  Result := ChainOf(GM, Group);
  if Result = '' then Result := DefaultOf(GM);
end;

{ ------------------------------------------------------------------------------------------ }
{ File groups                                                                                }
{ ------------------------------------------------------------------------------------------ }

type
  TMaskKind = (mkExt, mkExtGlob, mkBaseGlob, mkPathGlob, mkOther);
  TMask = record
    Kind: TMaskKind;
    Text: string;     // extension, or the glob
    Group: Integer;
  end;

var
  Masks: array of TMask;
  ExtRank: TStrIntMap;             // literal extension -> rank of its first mask
  GlobRanks: array of Integer;     // the masks that need a glob, in order
  OtherRank: Integer;
  GroupNames: TStringArray;

{ Glob with '*' and '?' ('?' is one UTF-8 character) on bytes. }
function Glob(const Mask, S: string): Boolean;
var
  m, n, StarM, StarN: Integer;

  function CharLen(const T: string; i: Integer): Integer; inline;
  var
    b: Byte;
  begin
    b := Ord(T[i]);
    if b < $C0 then Result := 1
    else if b < $E0 then Result := 2
    else if b < $F0 then Result := 3
    else Result := 4;
    while (Result > 1) and ((i + Result - 1 > Length(T)) or ((Ord(T[i + Result - 1]) and $C0) <> $80)) do
      Dec(Result);
  end;

begin
  m := 1; n := 1; StarM := 0; StarN := 0;
  while n <= Length(S) do
  begin
    if (m <= Length(Mask)) and (Mask[m] = '?') then
    begin
      Inc(m); Inc(n, CharLen(S, n));
    end
    else if (m <= Length(Mask)) and (Mask[m] <> '*') and (Mask[m] = S[n]) then
    begin
      Inc(m); Inc(n);
    end
    else if (m <= Length(Mask)) and (Mask[m] = '*') then
    begin
      StarM := m; StarN := n; Inc(m);
    end
    else if StarM > 0 then
    begin
      m := StarM + 1; Inc(StarN, CharLen(S, StarN)); n := StarN;
    end
    else
      Exit(False);
  end;
  while (m <= Length(Mask)) and (Mask[m] = '*') do Inc(m);
  Result := m > Length(Mask);
end;

function AsciiLower(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then Result[i] := Chr(Ord(Result[i]) + 32);
end;

procedure SplitName(const Name: string; out LcBase, LcExt: string);
var
  p: Integer;
begin
  p := LastDelimiter('/', Name);
  LcBase := AsciiLower(Copy(Name, p + 1, MaxInt));
  p := LastDelimiter('.', LcBase);
  if p > 0 then LcExt := Copy(LcBase, p + 1, MaxInt) else LcExt := '';
end;

function MaskMatches(const M: TMask; const LcName, LcBase, LcExt: string): Boolean;
begin
  case M.Kind of
    mkExt: Result := LcExt = M.Text;
    mkExtGlob: Result := Glob(M.Text, LcExt);
    mkBaseGlob: Result := Glob(M.Text, LcBase);
    mkPathGlob: Result := Glob(M.Text, LcName);
  else
    Result := False;
  end;
end;

function FileGroupRank(const Name: string): Integer;
var
  LcBase, LcExt, LcName: string;
  i, r: Integer;
begin
  SplitName(Name, LcBase, LcExt);
  Result := ExtRank.Get(LcExt, MaxInt);
  LcName := '';
  for i := 0 to High(GlobRanks) do
  begin
    r := GlobRanks[i];
    if r >= Result then Break;
    if (Masks[r].Kind = mkPathGlob) and (LcName = '') then LcName := AsciiLower(Name);
    if MaskMatches(Masks[r], LcName, LcBase, LcExt) then Exit(r);
  end;
  if Result = MaxInt then Result := OtherRank;
end;

function FileGroupMatches(const Name: string): QWord;
var
  LcBase, LcExt, LcName: string;
  i, r: Integer;
begin
  Result := 0;
  SplitName(Name, LcBase, LcExt);
  r := ExtRank.Get(LcExt);
  if r >= 0 then Result := QWord(1) shl Masks[r].Group;
  LcName := '';
  for i := 0 to High(GlobRanks) do
  begin
    r := GlobRanks[i];
    if (Masks[r].Kind = mkPathGlob) and (LcName = '') then LcName := AsciiLower(Name);
    if MaskMatches(Masks[r], LcName, LcBase, LcExt) then
      Result := Result or (QWord(1) shl Masks[r].Group);
  end;
end;

function FileGroupRankCount: Integer;
begin
  Result := Length(Masks);
end;

function FileGroupNames: TStringArray;
begin
  Result := Copy(GroupNames);
end;

function HasWildcard(const S: string): Boolean;
begin
  Result := (Pos('*', S) > 0) or (Pos('?', S) > 0);
end;

procedure BuildFileGroups;
var
  g, n: Integer;
  T, Ext: string;
begin
  SetLength(GroupNames, Length(FILE_GROUPS));
  Masks := nil;
  GlobRanks := nil;
  OtherRank := -1;
  ExtRank.Init(512);
  for g := 0 to High(FILE_GROUPS) do
  begin
    GroupNames[g] := FILE_GROUPS[g].Name;
    for T in FILE_GROUPS[g].Masks.Split([' ']) do
    begin
      if T = '' then Continue;
      n := Length(Masks);
      SetLength(Masks, n + 1);
      Masks[n].Group := g;
      Masks[n].Text := AsciiLower(T);
      if T = '<other>' then
      begin
        Masks[n].Kind := mkOther;
        OtherRank := n;
        Continue;
      end;
      if Pos('/', T) > 0 then Masks[n].Kind := mkPathGlob
      else if Copy(T, 1, 2) = '*.' then
      begin
        Ext := Copy(Masks[n].Text, 3, MaxInt);
        Masks[n].Text := Ext;
        if HasWildcard(Ext) or (Pos('.', Ext) > 0) then
        begin
          if Pos('.', Ext) > 0 then
          begin
            // "*.a.b": the name part is not '*' alone -> a glob on the base name
            Masks[n].Kind := mkBaseGlob;
            Masks[n].Text := AsciiLower(T);
          end
          else
            Masks[n].Kind := mkExtGlob;
        end
        else
        begin
          Masks[n].Kind := mkExt;
          if ExtRank.Get(Ext) < 0 then ExtRank.Put(Ext, n);
          Continue;
        end;
      end
      else if T = '*' then Masks[n].Kind := mkBaseGlob
      else Masks[n].Kind := mkBaseGlob;
      SetLength(GlobRanks, Length(GlobRanks) + 1);
      GlobRanks[High(GlobRanks)] := n;
    end;
  end;
  if OtherRank < 0 then
  begin
    // files that match nothing sort last
    n := Length(Masks);
    SetLength(Masks, n + 1);
    Masks[n].Kind := mkOther;
    Masks[n].Group := 0;
    OtherRank := n;
  end;
end;

{ ------------------------------------------------------------------------------------------ }
{ Text                                                                                       }
{ ------------------------------------------------------------------------------------------ }

function PresetTableLines: TStringArray;
var
  r, n: Integer;
  L: string;
begin
  Result := nil;
  for r := 0 to High(PRESETS) do
    with PRESETS[r] do
    begin
      L := Name;
      if Lo > 0 then
        if Lo = Hi then L := L + ' [' + IntToStr(Lo) + ']'
        else L := L + ' [' + IntToStr(Lo) + '-' + IntToStr(Hi) + ']';
      if Group <> '' then L := L + ' ' + Group;
      L := L + ' = ' + Chain;
      if MtAt > 0 then L := L + '   ; with ' + IntToStr(MtAt) + '+ threads: ' + MtChain;
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := L;
    end;
end;

function FileGroupLines: TStringArray;
var
  g, n: Integer;
  T: string;
begin
  Result := nil;
  for g := 0 to High(FILE_GROUPS) do
  begin
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n] := FILE_GROUPS[g].Name;
    for T in FILE_GROUPS[g].Masks.Split([' ']) do
      if T <> '' then
      begin
        n := Length(Result);
        SetLength(Result, n + 1);
        Result[n] := T;
      end;
  end;
end;

procedure BuildRowIndex;
var
  r: Integer;
begin
  RowIndex.Init(Length(PRESETS));
  for r := High(PRESETS) downto 0 do RowIndex.Put(PRESETS[r].Name, r);
end;

initialization
  BuildRowIndex;
  BuildFileGroups;
end.
