{
  WryeBashTagGenerator-NG-debug : READ-ONLY DEBUG FORK
  ----------------------------------------------------
  Same detection logic as WryeBashTagGenerator-NG, but:

    * NEVER writes to plugin headers. The single SetEditValue() call that
      mutates SNAM is short-circuited, g_AddTags is forced False, and the
      "Write suggested tags to header" checkbox is hidden in the prompt.
    * Emits a per-decision trace to a log file. For every tag the script
      considers on every record it touches, the log records the reason the
      tag was SUGGESTED or SKIPPED (template-flag gate, conflict state,
      no-difference, identical edit values, etc.).
    * Three verbosity levels (set g_DebugLevel below):
        DBG_PER_TAG       (1)  per-tag-per-record verdict only
        DBG_PER_COMPARE   (2)  + every Compare*/Evaluate*/DiffSubrecordList call (DEFAULT)
        DBG_LEAF_DIFFS    (3)  + actual differing edit-value snippets
    * Optional filters (g_DebugFilterFormID / g_DebugFilterTag) restrict
      output to a specific record (load-order FormID hex, e.g. '00013602')
      and / or a specific tag (e.g. 'Actors.Factions').

  Output file: <xEdit folder>\Edit Scripts\WryeBashTagGenerator-NG-debug.log
  The full path is also written to xEdit Messages at the end of the run.

  This file is a fork of WryeBashTagGenerator-NG.pas (base SHA: 2bc4866,
  plus the 1.9.2.0 multifile refactor applied to both files together).
  Sync detection-logic changes manually; do not change behavior in this
  file unless you also intend to debug an instrumentation bug.

  Games:    FO3/FNV/FO4/TES4/TES4R/TES5/SSE/Enderal/EnderalSE
  Requires: xEdit 4.1.4 or newer (script aborts on older builds)
  Hotkey:   F12
}


Unit WryeBashTagGeneratorNGDebug;

Uses 
  Dialogs;

Const 
  ScriptName    = 'WryeBashTagGenerator-NG-debug';
  ScriptVersion = '1.9.2.0-debug';
  MinXEditVer   = $04010400; // 4.1.4 (native StringList set ops + assumed API surface)
  ScriptAuthor  = 'Beermotor';
  ScriptEmail   = 'NO SUPPORT';
  ScaleFactor   = Screen.PixelsPerInch / 96;

  // Verbosity levels for the debug trace.
  DBG_OFF         = 0;   // no debug output (effectively production)
  DBG_PER_TAG     = 1;   // one line per (record, tag) verdict
  DBG_PER_COMPARE = 2;   // + every Compare*/Evaluate*/DiffSubrecordList call
  DBG_LEAF_DIFFS  = 3;   // + actual differing edit-value snippets

  // ---- Edit these to tune the trace -------------------------------------
  DebugLevel       = DBG_PER_COMPARE;  // 1=per-tag, 2=per-compare, 3=leaf-diffs
  DebugFilterForm  = '';               // load-order FormID hex (e.g. '00013602'); '' = no filter
  DebugFilterTag   = '';               // exact tag name (e.g. 'Actors.Factions'); '' = no filter
  // -----------------------------------------------------------------------


Var 
  slBadTags        : TStringList;
  slDifferentTags  : TStringList;
  slExistingTags   : TStringList;
  slLog               : TStringList;
  slTagRelationships  : TStringList;
  slSuggestedTags     : TStringList;
  slDeprecatedTags : TStringList;
  slOutToFileTags  : TStringList;

  g_FileName       : string;
  g_Tag            : string;
  g_AddTags        : boolean;
  g_AddFile        : boolean;
  g_LogTests              : boolean;
  g_ShowTagRelationships  : boolean;
  g_HeuristicForceTags    : boolean;

  // User-requested run abort (set via the header/BashTags discrepancy dialog).
  // Release-script path; debug fork does not mutate headers, but honours the
  // flag so an abort raised in a release run can't be lost during a debug run.
  g_AbortRun       : boolean;

  // ---- Debug-fork state ----------------------------------------------
  g_DebugLogPath          : string;             // resolved log file path
  g_DebugCurrentRecord    : IwbMainRecord;      // record currently being processed
  g_DebugCurrentTag       : string;             // tag currently being considered
  // xEdit's PascalScript (JvInterpreter) has no AssignFile/TextFile/WriteLn -
  // file IO is buffered through a TStringList and flushed via SaveToFile.
  g_DebugLog              : TStringList;        // in-memory log buffer
  g_DebugLogReady         : boolean;            // True while buffer is usable
  g_DebugIndent           : integer;            // visual nesting (0 = top)
  g_DebugSuggestedSnap    : integer;            // slSuggestedTags.Count snapshot at start of a tag

Function wbIsOblivion: boolean;
Begin
  Result := (wbGameMode = gmTES4) or (wbGameMode = gmTES4R);
End;


Function wbIsOblivionR: boolean;
Begin
  Result := wbGameMode = gmTES4R;
End;


Function wbIsSkyrim: boolean;
Begin
  Result := (wbGameMode = gmTES5) Or (wbGameMode = gmEnderal) Or (wbGameMode = gmSSE) Or (wbGameMode = gmTES5VR) Or (wbGameMode = gmEnderalSE);
End;


Function wbIsSkyrimSE: boolean;
Begin
  Result := (wbGameMode = gmSSE) Or (wbGameMode = gmTES5VR) Or (wbGameMode = gmEnderalSE);
End;


Function wbIsFallout3: boolean;
Begin
  Result := wbGameMode = gmFO3;
End;


Function wbIsFalloutNV: boolean;
Begin
  Result := wbGameMode = gmFNV;
End;


Function wbIsFallout4: boolean;
Begin
  Result := (wbGameMode = gmFO4) Or (wbGameMode = gmFO4VR);
End;


Function wbIsFallout76: boolean;
Begin
  Result := wbGameMode = gmFO76;
End;


Function wbIsEnderal: boolean;
Begin
  Result := wbGameMode = gmEnderal;
End;


Function wbIsEnderalSE: boolean;
Begin
  Result := wbGameMode = gmEnderalSE;
End;

Procedure LogInfo(AText: String);
Begin
  AddMessage('[INFO] ' + AText);
End;


Procedure LogWarn(AText: String);
Begin
  AddMessage('[WARN] ' + AText);
End;


Procedure LogError(AText: String);
Begin
  AddMessage('[ERRO] ' + AText);
End;


// ===========================================================================
// Debug-fork instrumentation
// ===========================================================================

Function DbgRecordTag: string;
Var
  sFid : string;
  sEid : string;
  sSig : string;
  sFil : string;
Begin
  If Not Assigned(g_DebugCurrentRecord) Then
    Begin
      Result := '[<no-record>]';
      Exit;
    End;
  sSig := Signature(g_DebugCurrentRecord);
  sFid := IntToHex(GetLoadOrderFormID(g_DebugCurrentRecord), 8);
  sEid := EditorID(g_DebugCurrentRecord);
  sFil := GetFileName(GetFile(g_DebugCurrentRecord));
  If sEid = '' Then
    Result := Format('[%s:%s @ %s]', [sSig, sFid, sFil])
  Else
    Result := Format('[%s:%s "%s" @ %s]', [sSig, sFid, sEid, sFil]);
End;


Function DbgFiltered: boolean;
Var
  sFid : string;
Begin
  Result := False;
  If DebugFilterTag <> '' Then
    If Not SameText(g_DebugCurrentTag, DebugFilterTag) Then
      Begin Result := True; Exit; End;
  If DebugFilterForm <> '' Then
    Begin
      If Not Assigned(g_DebugCurrentRecord) Then
        Begin Result := True; Exit; End;
      sFid := IntToHex(GetLoadOrderFormID(g_DebugCurrentRecord), 8);
      If Not SameText(sFid, DebugFilterForm) Then
        Result := True;
    End;
End;


Procedure DbgWriteRaw(Const s: string);
Var
  sIndent : string;
  i       : integer;
Begin
  If Not g_DebugLogReady Then Exit;
  sIndent := '';
  For i := 1 To g_DebugIndent Do
    sIndent := sIndent + '  ';
  Try
    g_DebugLog.Add(sIndent + s);
  Except
    // Swallow buffer errors - debug-only path, never abort the script.
  End;
End;


Procedure DbgLog(ALevel: integer; Const s: string);
Begin
  If DebugLevel < ALevel Then Exit;
  If DbgFiltered Then Exit;
  DbgWriteRaw(s);
End;


Procedure DbgLogUnfiltered(ALevel: integer; Const s: string);
// Bypasses tag/form filter; used for record + file headers so the log
// is still readable when filters are active.
Begin
  If DebugLevel < ALevel Then Exit;
  DbgWriteRaw(s);
End;


Function DbgShortVal(Const s: string): string;
// Edit values can be very long (e.g. full Items array dumps). Trim for log.
Begin
  If Length(s) > 200 Then
    Result := Copy(s, 1, 197) + '...'
  Else
    Result := s;
End;


Function DbgEdv(AElement: IInterface): string;
// Safe GetEditValue for nil-tolerant logging.
Begin
  If Not Assigned(AElement) Then
    Result := '<nil>'
  Else
    Result := DbgShortVal(GetEditValue(AElement));
End;


Function DbgPath(AElement: IInterface): string;
// Path relative to the containing record (xEdit's Path() is full).
Var
  s : string;
Begin
  If Not Assigned(AElement) Then
    Begin Result := '<nil>'; Exit; End;
  s := Path(AElement);
  // Path() typically starts with the record signature; strip it for brevity.
  If Length(s) > 5 Then
    Result := Copy(s, 6, Length(s))
  Else
    Result := s;
End;


Procedure DbgSuggestSnapshot;
Begin
  g_DebugSuggestedSnap := slSuggestedTags.Count;
End;


Function DbgWasSuggested: boolean;
Begin
  Result := slSuggestedTags.Count > g_DebugSuggestedSnap;
End;


Function DbgConflictName(AState: TConflictThis): string;
Begin
  Case AState Of
    caUnknown          : Result := 'caUnknown';
    caOnlyOne          : Result := 'caOnlyOne';
    caNoConflict       : Result := 'caNoConflict';
    caConflictBenign   : Result := 'caConflictBenign';
    caOverride         : Result := 'caOverride';
    caConflict         : Result := 'caConflict';
    caConflictCritical : Result := 'caConflictCritical';
  Else
    Result := 'caState_' + IntToStr(Ord(AState));
  End;
End;


Function TagIsRemoved(Const t: String): boolean;
Begin
  Result := SameText(t, 'Merge') Or SameText(t, 'ScriptContents');
End;


Procedure ExpandOneAliasTo(Const t: String; dest: TStringList);

Var 
  s : string;
Begin
  s := Trim(t);
  If s = '' Then
    Exit;
  If TagIsRemoved(s) Then
    Exit;

  If SameText(s, 'Actors.Perks.Add') Then
    dest.Add('NPC.Perks.Add')
  Else If SameText(s, 'Actors.Perks.Change') Then
         dest.Add('NPC.Perks.Change')
  Else If SameText(s, 'Actors.Perks.Remove') Then
         dest.Add('NPC.Perks.Remove')
  Else If SameText(s, 'Body-F') Then
         dest.Add('R.Body-F')
  Else If SameText(s, 'Body-M') Then
         dest.Add('R.Body-M')
  Else If SameText(s, 'Body-Size-F') Then
         dest.Add('R.Body-Size-F')
  Else If SameText(s, 'Body-Size-M') Then
         dest.Add('R.Body-Size-M')
  Else If SameText(s, 'C.GridFlags') Then
         dest.Add('C.ForceHideLand')
  Else If SameText(s, 'Derel') Then
         dest.Add('Relations.Remove')
  Else If SameText(s, 'Eyes') Or SameText(s, 'Eyes-D') Or SameText(s, 'Eyes-E') Or SameText(s, 'Eyes-R') Then
         dest.Add('R.Eyes')
  Else If SameText(s, 'Factions') Then
         dest.Add('Actors.Factions')
  Else If SameText(s, 'Hair') Then
         dest.Add('R.Hair')
  Else If SameText(s, 'Invent') Then
         Begin
           dest.Add('Invent.Add');
           dest.Add('Invent.Remove');
         End
  Else If SameText(s, 'InventOnly') Then
         Begin
           dest.Add('IIM');
           dest.Add('Invent.Add');
           dest.Add('Invent.Remove');
         End
  Else If SameText(s, 'Npc.EyesOnly') Then
         dest.Add('NPC.Eyes')
  Else If SameText(s, 'Npc.HairOnly') Then
         dest.Add('NPC.Hair')
  Else If SameText(s, 'NpcFaces') Then
         Begin
           dest.Add('NPC.Eyes');
           dest.Add('NPC.Hair');
           dest.Add('NPC.FaceGen');
         End
  Else If SameText(s, 'R.Relations') Then
         Begin
           dest.Add('R.Relations.Add');
           dest.Add('R.Relations.Change');
           dest.Add('R.Relations.Remove');
         End
  Else If SameText(s, 'Relations') Then
         Begin
           dest.Add('Relations.Add');
           dest.Add('Relations.Change');
         End
  Else If SameText(s, 'Voice-F') Then
         dest.Add('R.Voice-F')
  Else If SameText(s, 'Voice-M') Then
         dest.Add('R.Voice-M')
  Else
    dest.Add(s);
End;


Procedure NormalizeBashTagsInPlace(sl: TStringList);

Var 
  tmp : TStringList;
  i   : integer;
Begin
  tmp := TStringList.Create;
  tmp.Sorted       := True;
  tmp.Duplicates   := dupIgnore;
  tmp.CaseSensitive := False;
  Try
    For i := 0 To Pred(sl.Count) Do
      ExpandOneAliasTo(sl[i], tmp);
    sl.Clear;
    sl.AddStrings(tmp);
  Finally
    tmp.Free;
  End;
End;


Function TagsCommaTextEqual(slA: TStringList; slB: TStringList): boolean;

Var 
  tA : TStringList;
  tB : TStringList;
Begin
  tA := TStringList.Create;
  tB := TStringList.Create;
  Try
    tA.Sorted     := True;
    tA.Duplicates := dupIgnore;
    tB.Sorted     := True;
    tB.Duplicates := dupIgnore;
    tA.AddStrings(slA);
    tB.AddStrings(slB);
    Result := SameText(tA.CommaText, tB.CommaText);
  Finally
    tA.Free;
    tB.Free;
  End;
End;


Function PromptDeprecatedHeaderUpdate: boolean;
Begin
  Result := MessageDlg(
    'This plugin description contains deprecated Bash Tags (obsolete names Wrye Bash no longer uses).'#13#10 +
    'Update the {{BASH:...}} block to modern tag names when writing the header?',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes;
End;


Function Initialize: integer;
Var
  sLogDir : string;
Begin
  ClearMessages();

  LogInfo('--------------------------------------------------------------------------------');
  LogInfo(ScriptName + ' v' + ScriptVersion + ' by ' + ScriptAuthor + ' <' + ScriptEmail + '>');
  LogInfo('READ-ONLY DEBUG FORK - this script never writes to plugin headers.');
  LogInfo('--------------------------------------------------------------------------------');
  LogInfo(DataPath);

  // ---- Open the debug trace buffer ------------------------------------
  // xEdit's PascalScript (JvInterpreter) does not register TextFile,
  // AssignFile, Rewrite, WriteLn, Flush or CloseFile. The only practical
  // way to write text to disk from a script is TStringList.SaveToFile.
  // We therefore buffer all trace lines in g_DebugLog and flush via
  // SaveToFile (once per file in Process(), and again in Finalize).
  sLogDir          := ProgramPath + 'Edit Scripts\';
  g_DebugLogPath   := sLogDir + 'WryeBashTagGenerator-NG-debug.log';
  g_DebugLogReady  := False;
  g_DebugIndent    := 0;

  // Tell the user up-front exactly where we will (try to) write, so they
  // can find it even if Finalize never runs (script abort, exception, etc).
  AddMessage('');
  AddMessage('================================================================================');
  AddMessage('Debug trace target:');
  AddMessage('  ' + g_DebugLogPath);
  AddMessage('================================================================================');

  Try
    g_DebugLog := TStringList.Create;
    g_DebugLog.Add('# ' + ScriptName + ' v' + ScriptVersion);
    g_DebugLog.Add('# Generated: ' + DateTimeToStr(Now));
    g_DebugLog.Add('# DebugLevel=' + IntToStr(DebugLevel) +
                   '  FilterForm="' + DebugFilterForm + '"' +
                   '  FilterTag="'  + DebugFilterTag  + '"');
    g_DebugLog.Add('');
    // Probe write to surface permission errors NOW, not at the end of a
    // 30-minute run. SaveToFile will raise if the path is unwritable.
    g_DebugLog.SaveToFile(g_DebugLogPath);
    g_DebugLogReady := True;
    LogInfo('Debug trace OPEN: ' + g_DebugLogPath);
  Except
    on E: Exception Do
      Begin
        LogWarn('Could not initialize debug log buffer: ' +
                g_DebugLogPath + ' [' + E.ClassName + ': ' + E.Message +
                '] (continuing without trace)');
        g_DebugLogReady := False;
      End;
  End;

  // Read-only enforcement: g_AddTags AND g_AddFile are forced False here,
  // both prompt checkboxes are disabled in ShowPrompt, the only SetEditValue()
  // call in Process() is gated behind 'If False And bWriteHeader Then', and
  // the BashTags-file write block is replaced by a defensive LogWarn.
  g_AddTags  := False;
  g_AddFile  := False;
  g_LogTests             := True;
  g_ShowTagRelationships := True;
  g_HeuristicForceTags   := False;

  slLog := TStringList.Create;
  slLog.Sorted     := False;
  slLog.Duplicates := dupAccept;

  slTagRelationships := TStringList.Create;
  slTagRelationships.Sorted     := False;
  slTagRelationships.Duplicates := dupAccept;

  slSuggestedTags := TStringList.Create;
  slSuggestedTags.Sorted       := True;
  slSuggestedTags.Duplicates   := dupIgnore;
  slSuggestedTags.Delimiter    := ',';
  slSuggestedTags.CaseSensitive := False;

  slExistingTags := TStringList.Create;
  slExistingTags.CaseSensitive := False;

  slDifferentTags := TStringList.Create;
  slDifferentTags.Sorted     := True;
  slDifferentTags.Duplicates := dupIgnore;

  slBadTags := TStringList.Create;

  slDeprecatedTags := TStringList.Create;
  slDeprecatedTags.Sorted       := True;
  slDeprecatedTags.Duplicates   := dupIgnore;
  slDeprecatedTags.CaseSensitive := False;
  { Mirror Mopy/bash/bosh/__init__.py _removed_tags keys + _tag_aliases keys }
  slDeprecatedTags.CommaText :=
    'Actors.Perks.Add,Actors.Perks.Change,Actors.Perks.Remove,Body-F,Body-M,Body-Size-F,Body-Size-M,C.GridFlags,Derel,Eyes,Eyes-D,Eyes-E,Eyes-R,Factions,Hair,Invent,InventOnly,Merge,Npc.EyesOnly,Npc.HairOnly,NpcFaces,R.Relations,Relations,ScriptContents,Voice-F,Voice-M';

  // Wish I didn't have to make a new list for this, but script errors on AssignFile
  slOutToFileTags := TStringList.Create;

  g_AbortRun := False;

  If wbVersionNumber < MinXEditVer Then
    Begin
      LogWarn(Format('This script requires xEdit 4.1.4 or newer. Detected wbVersionNumber = $%s.',
                     [IntToHex(wbVersionNumber, 8)]));
      LogError('Cannot proceed because xEdit version is older than 4.1.4.');
      Result := 4;
      Exit;
    End;

  If ShowPrompt(ScriptName + ' v' + ScriptVersion) = mrAbort Then
    Begin
      LogError('Cannot proceed because user aborted execution');
      Result := 1;
      Exit;
    End;

  If wbIsFallout76 Then
    Begin
      LogError('Cannot proceed because CBash does not support Fallout 76');
      Result := 2;
      Exit;
    End;

  If wbIsFallout3 Then
    LogInfo('Using game mode: Fallout 3')
  Else If wbIsFalloutNV Then
         LogInfo('Using game mode: Fallout: New Vegas')
  Else If wbIsFallout4 Then
         LogInfo('Using game mode: Fallout 4')
  Else If wbIsOblivion Then
         LogInfo('Using game mode: Oblivion')
  Else If wbIsOblivionR Then
         LogInfo('Using game mode: Oblivion Remastered')
  Else If wbIsEnderal Then
         LogInfo('Using game mode: Enderal')
  Else If wbIsEnderalSE Then
         LogInfo('Using game mode: Enderal Special Edition')
  Else If wbIsSkyrimSE Then
         LogInfo('Using game mode: Skyrim Special Edition')
  Else If wbIsSkyrim Then
         LogInfo('Using game mode: Skyrim')
  Else
    Begin
      LogError('Cannot proceed because script does not support game mode');
      Result := 3;
      Exit;
    End;

  ScriptProcessElements := [etFile];
End;


Function Process(input: IInterface): integer;

Var 
  kDescription : IwbElement;
  kHeader      : IwbElement;
  sDescription : string;
  sTags        : string;
  i            : integer;
  f            : IwbFile;
  slScanResults: TStringList;
  slFinalTags  : TStringList;
  slNormExist  : TStringList;
  slDepFound   : TStringList;
  bWriteHeader : boolean;
  bHasWork     : boolean;
Begin

  If (ElementType(input) = etMainRecord) Then
    exit;

  // Honour prior user-requested abort.
  If g_AbortRun Then
    Exit;

  f := GetFile(input);
  g_FileName := GetFileName(f);

  // Start-of-Process state reset — per-plugin independence.
  // Mirrors the release script; see its Process for the rationale.
  slLog.Clear;
  slTagRelationships.Clear;
  slSuggestedTags.Clear;
  slExistingTags.Clear;
  slDifferentTags.Clear;
  slBadTags.Clear;
  slOutToFileTags.Clear;

  // Per-file banner in the debug trace.
  DbgLogUnfiltered(DBG_PER_TAG, '');
  DbgLogUnfiltered(DBG_PER_TAG, '================================================================================');
  DbgLogUnfiltered(DBG_PER_TAG, '== FILE: ' + g_FileName);
  DbgLogUnfiltered(DBG_PER_TAG, '================================================================================');

  AddMessage(#10);
  LogInfo('=== ' + g_FileName + ' ===');

  LogInfo('Processing... ' + IntToStr(RecordCount(f)) + ' records. Please wait. This could take a while.');

  For i := 0 To Pred(RecordCount(f)) Do
    ProcessRecord(RecordByIndex(f, i));

  LogInfo('--------------------------------------------------------------------------------');
  LogInfo(g_FileName);
  LogInfo('-------------------------------------------------------------------------- TESTS');

  If g_LogTests Then
    For i := 0 To Pred(slLog.Count) Do
      LogInfo(slLog[i]);

  LogInfo('------------------------------------------------------------------------ RESULTS');

  slScanResults := TStringList.Create;
  slFinalTags   := TStringList.Create;
  slNormExist   := TStringList.Create;
  slDepFound    := TStringList.Create;
  Try
    slScanResults.Sorted       := True;
    slScanResults.Duplicates   := dupIgnore;
    slScanResults.CaseSensitive := False;
    slFinalTags.Sorted         := True;
    slFinalTags.Duplicates     := dupIgnore;
    slFinalTags.CaseSensitive  := False;
    slNormExist.Sorted         := True;
    slNormExist.Duplicates     := dupIgnore;
    slNormExist.CaseSensitive  := False;

    kHeader := ElementBySignature(f, 'TES4');
    kDescription := ElementBySignature(kHeader, 'SNAM');
    If Assigned(kDescription) Then
      sDescription := GetEditValue(kDescription)
    Else
      sDescription := '';

    slExistingTags.Clear;
    slExistingTags.CommaText := RegExMatchGroup('{{BASH:(.*?)}}', sDescription, 1);

    slDepFound.Clear;
    StringListIntersection(slExistingTags, slDeprecatedTags, slDepFound);
    LogInfo(FormatTags(slDepFound, 'deprecated tag found:', 'deprecated tags found:', 'No deprecated tags found.'));

    slScanResults.Assign(slSuggestedTags);

    slFinalTags.Clear;
    slFinalTags.AddStrings(slExistingTags);
    slFinalTags.AddStrings(slScanResults);
    NormalizeBashTagsInPlace(slFinalTags);

    slNormExist.Clear;
    slNormExist.AddStrings(slExistingTags);
    NormalizeBashTagsInPlace(slNormExist);

    bHasWork := (slScanResults.Count > 0) Or (slDepFound.Count > 0) Or g_AddFile;

    If Not bHasWork Then
      LogInfo('No tags are suggested for this plugin.')
    Else
      Begin
        bWriteHeader := False;  // READ-ONLY DEBUG FORK: header writes hard-disabled
        If bWriteHeader And (slDepFound.Count > 0) Then
          If Not PromptDeprecatedHeaderUpdate Then
            Begin
              bWriteHeader := False;
              LogWarn('Deprecated Bash Tags present; user declined header update — description not modified.');
            End;

        slDifferentTags.Clear;
        StringListDifference(slScanResults, slExistingTags, slDifferentTags);
        slBadTags.Clear;
        StringListDifference(slExistingTags, slScanResults, slBadTags);

        // Deprecated tags are reported separately under "deprecated tags found:";
        // they are not "bad" (the user just hasn't migrated yet), so strip them out.
        If slDepFound.Count > 0 Then
          For i := Pred(slBadTags.Count) DownTo 0 Do
            If slDepFound.IndexOf(slBadTags[i]) <> -1 Then
              slBadTags.Delete(i);

        If (slScanResults.Count = 0) And (slDepFound.Count = 0) And TagsCommaTextEqual(slFinalTags, slNormExist) And Not g_AddFile Then
          Begin
            LogInfo(FormatTags(slExistingTags, 'existing tag found:', 'existing tags found:', 'No existing tags found.'));
            LogInfo(FormatTags(slScanResults, 'suggested tag:', 'suggested tags:', 'No suggested tags.'));
            LogWarn('No tags to add.' + #13#10);
          End
        Else
          Begin
            If bWriteHeader Then
              Begin
                kDescription := ElementBySignature(kHeader, 'SNAM');
                If Not Assigned(kDescription) Then
                  kDescription := Add(kHeader, 'SNAM', True);

                sDescription := GetEditValue(kDescription);
                sTags        := Format('{{BASH:%s}}', [slFinalTags.DelimitedText]);

                If (Length(sDescription) = 0) And (slFinalTags.Count > 0) Then
                  sDescription := sTags
                Else If (Not TagsCommaTextEqual(slFinalTags, slNormExist)) Or (slDepFound.Count > 0) Then
                       Begin
                         If slExistingTags.Count = 0 Then
                           sDescription := sDescription + #10#10 + sTags
                         Else
                           sDescription := RegExReplace('{{BASH:.*?}}', sTags, sDescription);
                       End;

                // READ-ONLY DEBUG FORK: header write deliberately suppressed.
                // SetEditValue(kDescription, sDescription);
                LogWarn('READ-ONLY DEBUG FORK: header write suppressed (would have written: ' + sDescription + ')');

                LogInfo(FormatTags(slBadTags,       'bad tag removed:',          'bad tags removed:',          'No bad tags found.'));
                LogInfo(FormatTags(slDifferentTags, 'tag added to file header:', 'tags added to file header:', 'No tags added.'));
              End
            Else
              Begin
                LogInfo(FormatTags(slBadTags,       'bad tag found:',         'bad tags found:',         'No bad tags found.'));
                LogInfo(FormatTags(slDifferentTags, 'suggested tag to add:',  'suggested tags to add:',  'No suggested tags to add.'));
              End;

            LogInfo(FormatTags(slExistingTags, 'existing tag found:', 'existing tags found:', 'No existing tags found.'));
            LogInfo(FormatTags(slFinalTags, 'suggested tag overall:', 'suggested tags overall:', 'No suggested tags overall.'));

            If g_ShowTagRelationships Then
              For i := 0 To Pred(slTagRelationships.Count) Do
                LogInfo(slTagRelationships[i]);

            // Read-only debug fork: never write a BashTags file.
            // The 'Write suggested tags to file' checkbox is disabled in
            // ShowPrompt and g_AddFile is forced False in Initialize, so
            // this branch is unreachable; the LogWarn is a defense-in-depth
            // canary in case someone wires it back up.
            If g_AddFile Then
              LogWarn('READ-ONLY DEBUG FORK: refused to write to BashTags file (use the production script).');
          End;
      End;

  Finally
    slScanResults.Free;
    slFinalTags.Free;
    slNormExist.Free;
    slDepFound.Free;
  End;

  slLog.Clear;
  slTagRelationships.Clear;
  slSuggestedTags.Clear;
  slExistingTags.Clear;
  slDifferentTags.Clear;
  slBadTags.Clear;
  slOutToFileTags.Clear;

  // Crash-safety flush: write the buffer to disk after every plugin so a
  // mid-run abort still leaves a usable partial trace on disk.
  If g_DebugLogReady Then
    Try
      g_DebugLog.SaveToFile(g_DebugLogPath);
    Except
      // ignore - Finalize will report the error
    End;

  AddMessage(#10);
End;


Function ProcessRecord(e: IwbMainRecord): integer;

Var 
  o             : IwbMainRecord;
  sSignature    : string;
  ConflictState : TConflictThis;
  iFormID       : integer;
Begin
  g_DebugCurrentRecord := e;
  ConflictState        := ConflictAllForMainRecord(e);

  DbgLogUnfiltered(DBG_PER_TAG, '');
  DbgLogUnfiltered(DBG_PER_TAG, Format('--- RECORD %s  [conflict=%s] ---',
    [DbgRecordTag, DbgConflictName(ConflictState)]));

  If (ConflictState = caUnknown)
     Or (ConflictState = caOnlyOne)
     Or (ConflictState = caNoConflict) Then
    Begin
      DbgLogUnfiltered(DBG_PER_TAG, Format('  ProcessRecord: SKIP entire record (conflict=%s; no override conflict to analyze)',
        [DbgConflictName(ConflictState)]));
      g_DebugCurrentRecord := Nil;
      Exit;
    End;

  Try

  // exit if the record should not be processed
  If SameText(g_FileName, 'Dawnguard.esm') Then
    Begin
      iFormID := GetLoadOrderFormID(e) And $00FFFFFF;
      If (iFormID = $00016BCF)
         Or (iFormID = $0001EE6D)
         Or (iFormID = $0001FA4C)
         Or (iFormID = $00039F67)
         Or (iFormID = $0006C3B6) Then
        Exit;
    End;

  // get master record if record is an override
  o := Master(e);

  If Not Assigned(o) Then
    Exit;

  // if record overrides several masters, then get the last one
  o := HighestOverrideOrSelf(o, OverrideCount(o));

  If Equals(e, o) Then
    Exit;

  // stop processing deleted records to avoid errors
  If GetIsDeleted(e)
     Or GetIsDeleted(o) Then
    Exit;

  sSignature := Signature(e);

  logInfo(Name(e));

  // -------------------------------------------------------------------------------
  // GROUP: Supported tags exclusive to FNV
  // -------------------------------------------------------------------------------
  If wbIsFalloutNV Then
    If sSignature = 'WEAP' Then
      ProcessTag('WeaponMods', e, o);

  // -------------------------------------------------------------------------------
  // GROUP: Supported tags exclusive to TES4
  // -------------------------------------------------------------------------------
  If wbIsOblivion or wbIsOblivionR Then
    Begin
      If ContainsStr('CREA NPC_', sSignature) Then
        Begin
          ProcessTag('Actors.Spells', e, o);

          If sSignature = 'CREA' Then
            ProcessTag('Creatures.Blood', e, o);
        End

      Else If sSignature = 'RACE' Then
             Begin
               ProcessRaceSpells(e, o);
               ProcessTag('R.Attributes-F', e, o);
               ProcessTag('R.Attributes-M', e, o);
             End

      Else If sSignature = 'ROAD' Then
             ProcessTag('Roads', e, o)

      Else If sSignature = 'SPEL' Then
             ProcessTag('SpellStats', e, o);
    End;

  // -------------------------------------------------------------------------------
  // GROUP: Supported tags exclusive to TES5, SSE
  // -------------------------------------------------------------------------------
  If wbIsSkyrim Then
    Begin
      // NOTE: Each signature branch below is an INDEPENDENT If (not Else If).
      // The Keywords signature list contains 'NPC_', so an If/Else If chain
      // would short-circuit on Keywords and silently skip the dedicated NPC_
      // branch (NPC.Perks.*, Actors.Factions, NPC.AIPackageOverrides,
      // Actors.Spells, NPC.AttackRace, NPC.CrimeFaction, NPC.DefaultOutfit).
      // Per-tag dedup is handled by ProcessTag, so independent Ifs are safe.
      If sSignature = 'CELL' Then
        Begin
          ProcessTag('C.Location', e, o);
          ProcessTag('C.LockList', e, o);
          ProcessTag('C.Regions', e, o);
          ProcessTag('C.SkyLighting', e, o);
        End;

      If ContainsStr('ACTI ALCH AMMO ARMO BOOK FLOR FURN INGR KEYM LCTN MGEF MISC NPC_ SCRL SLGM SPEL TACT WEAP', sSignature) Then
        ProcessTag('Keywords', e, o);

      If sSignature = 'FACT' Then
        Begin
          ProcessTag('Relations.Add', e, o);
          ProcessTag('Relations.Change', e, o);
          ProcessTag('Relations.Remove', e, o);
        End;

      If sSignature = 'NPC_' Then
        Begin
          ProcessTag('NPC.Perks.Add', e, o);
          ProcessTag('NPC.Perks.Change', e, o);
          ProcessTag('NPC.Perks.Remove', e, o);

          g_Tag := 'Actors.Factions';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Factions', False, False) Then
            ProcessTag('Actors.Factions', e, o);

          g_Tag := 'NPC.AIPackageOverrides';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use AI Packages', False, False) Then
            ProcessTag('NPC.AIPackageOverrides', e, o);

          // Skyrim/SSE Actors.Spells — skip if the NPC inherits its spell list
          // from a template (modifying SPLO directly would be ignored by the engine).
          g_Tag := 'Actors.Spells';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Spell List', False, False) Then
            ProcessTag('Actors.Spells', e, o);

          ProcessTag('NPC.AttackRace', e, o);
          ProcessTag('NPC.CrimeFaction', e, o);
          ProcessTag('NPC.DefaultOutfit', e, o);
        End;

      If sSignature = 'OTFT' Then
        Begin
          ProcessTag('Outfits.Add', e, o);
          ProcessTag('Outfits.Remove', e, o);
        End;

      // R.AddSpells / R.ChangeSpells (Skyrim/SSE/Enderal). ProcessRaceSpells
      // emits the Add/Change split (Adds-only -> R.AddSpells, Removes present
      // -> R.ChangeSpells) using the per-game SPLO array path.
      If sSignature = 'RACE' Then
        ProcessRaceSpells(e, o);
    End;

  // -------------------------------------------------------------------------------
  // GROUP: Supported tags exclusive to FO3, FNV
  // -------------------------------------------------------------------------------
  If wbIsFallout3 Or wbIsFalloutNV Then
    Begin
      If sSignature = 'FLST' Then
        ProcessTag('Deflst', e, o);

      g_Tag := 'Destructible';
      If ContainsStr('ACTI ALCH AMMO BOOK CONT DOOR FURN IMOD KEYM MISC MSTT PROJ TACT TERM WEAP', sSignature) Then
        ProcessTag('Destructible', e, o)

        // special handling for CREA and NPC_ record types
      Else If ContainsStr('CREA NPC_', sSignature) Then
             If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Model/Animation', False, False) Then
               ProcessTag('Destructible', e, o)

               // added in Wrye Bash 307 Beta 6
      Else If sSignature = 'FACT' Then
             Begin
               ProcessTag('Relations.Add', e, o);
               ProcessTag('Relations.Change', e, o);
               ProcessTag('Relations.Remove', e, o);
             End;
    End;

  // -------------------------------------------------------------------------------
  // GROUP: Supported tags exclusive to FO3, FNV, TES4
  // -------------------------------------------------------------------------------
  If wbIsFallout3 Or wbIsFalloutNV Or wbIsOblivion Or wbIsOblivionR Then
    Begin
      If ContainsStr('CREA NPC_', sSignature) Then
        Begin
          If sSignature = 'CREA' Then
            ProcessTag('Creatures.Type', e, o);

          g_Tag := 'Actors.Factions';
          If wbIsOblivion Or wbIsOblivionR Or Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Factions', False, False) Then
            ProcessTag('Actors.Factions', e, o);

          If sSignature = 'NPC_' Then
            Begin
              ProcessTag('NPC.Eyes', e, o);
              ProcessTag('NPC.FaceGen', e, o);
              ProcessTag('NPC.Hair', e, o);

              // Oblivion-only here: NPC.Class / NPC.Race for FO3/FNV/Skyrim are
              // emitted further down with template-flag gating. Oblivion has no
              // template flag system, so emit unconditionally.
              If wbIsOblivion Or wbIsOblivionR Then
                Begin
                  ProcessTag('NPC.Class', e, o);
                  ProcessTag('NPC.Race',  e, o);
                End;
            End;
        End

      Else If sSignature = 'RACE' Then
             Begin
               ProcessTag('R.Body-F', e, o);
               ProcessTag('R.Body-M', e, o);
               ProcessTag('R.Body-Size-F', e, o);
               ProcessTag('R.Body-Size-M', e, o);
               ProcessTag('R.Eyes', e, o);
               ProcessTag('R.Hair', e, o);
               ProcessTag('R.Relations.Add', e, o);
               ProcessTag('R.Relations.Change', e, o);
               ProcessTag('R.Relations.Remove', e, o);
             End;
    End;

  // -------------------------------------------------------------------------------
  // GROUP: Supported tags exclusive to FO3, FNV, TES5, SSE
  // -------------------------------------------------------------------------------
  If wbIsFallout3 Or wbIsFalloutNV Or wbIsSkyrim Then
    Begin
      If ContainsStr('CREA NPC_', sSignature) Then
        Begin
          g_Tag := 'Actors.ACBS';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Stats', False, False) Then
            ProcessTag('Actors.ACBS', e, o);

          g_Tag := 'Actors.AIData';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use AI Data', False, False) Then
            ProcessTag('Actors.AIData', e, o);

          g_Tag := 'Actors.AIPackages';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use AI Packages', False, False) Then
            ProcessTag('Actors.AIPackages', e, o);

          If sSignature = 'CREA' Then
            If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Model/Animation', False, False) Then
              ProcessTag('Actors.Anims', e, o);

          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Traits', False, False) Then
            Begin
              ProcessTag('Actors.CombatStyle', e, o);
              ProcessTag('Actors.DeathItem', e, o);
            End;

          g_Tag := 'Actors.Skeleton';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Model/Animation', False, False) Then
            ProcessTag('Actors.Skeleton', e, o);

          g_Tag := 'Actors.Stats';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Stats', False, False) Then
            ProcessTag('Actors.Stats', e, o);

          If wbIsFallout3 Or wbIsFalloutNV Or (sSignature = 'NPC_') Then
            ProcessTag('Actors.Voice', e, o);

          If sSignature = 'NPC_' Then
            Begin
              g_Tag := 'NPC.Class';
              If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Traits', False, False) Then
                ProcessTag('NPC.Class', e, o);

              g_Tag := 'NPC.Race';
              If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Traits', False, False) Then
                ProcessTag('NPC.Race', e, o);
            End;

          g_Tag := 'Scripts';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Script', False, False) Then
            ProcessTag(g_Tag, e, o);

          // FO3/FNV Actors.Spells (CREA + NPC_). Skyrim/SSE NPC_ Actors.Spells is
          // handled by the dedicated wbIsSkyrim NPC_ block above. The FNV/FO3
          // template flag is named 'Use Actor Effect List' (not 'Use Spell List').
          If wbIsFallout3 Or wbIsFalloutNV Then
            Begin
              g_Tag := 'Actors.Spells';
              If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Actor Effect List', False, False) Then
                ProcessTag('Actors.Spells', e, o);
            End;
        End;

      If sSignature = 'CELL' Then
        Begin
          ProcessTag('C.Acoustic', e, o);
          ProcessTag('C.Encounter', e, o);
          ProcessTag('C.ForceHideLand', e, o);
          ProcessTag('C.ImageSpace', e, o);
        End;

      If sSignature = 'RACE' Then
        Begin
          ProcessTag('R.Ears', e, o);
          ProcessTag('R.Head', e, o);
          ProcessTag('R.Mouth', e, o);
          ProcessTag('R.Teeth', e, o);
          ProcessTag('R.Skills', e, o);
          ProcessTag('R.Description', e, o);
          ProcessTag('R.Voice-F', e, o);
          ProcessTag('R.Voice-M', e, o);
        End;

      If ContainsStr('ACTI ALCH ARMO CONT DOOR FLOR FURN INGR KEYM LIGH LVLC MISC QUST WEAP', sSignature) Then
        ProcessTag('Scripts', e, o);
    End;

  // -------------------------------------------------------------------------------
  // GROUP: Supported tags exclusive to FO3, FNV, TES4, TES5, SSE
  // -------------------------------------------------------------------------------
  If wbIsFallout3 Or wbIsFalloutNV Or wbIsOblivion Or wbIsOblivionR Or wbIsSkyrim Then
    Begin
      If sSignature = 'CELL' Then
        Begin
          ProcessTag('C.Climate', e, o);
          ProcessTag('C.Light', e, o);
          ProcessTag('C.MiscFlags', e, o);
          ProcessTag('C.Music', e, o);
          ProcessTag('C.Name', e, o);
          ProcessTag('C.Owner', e, o);
          ProcessTag('C.RecordFlags', e, o);
          ProcessTag('C.Water', e, o);
        End;

      // TAG: Delev, Relev
      If ContainsStr('LVLC LVLI LVLN LVSP', sSignature) Then
        ProcessDelevRelevTags(e, o);

      If ContainsStr('ACTI ALCH AMMO APPA ARMO BOOK BSGN CLAS CLOT DOOR FLOR FURN INGR KEYM LIGH MGEF MISC SGST SLGM WEAP', sSignature) Then
        Begin
          ProcessTag('Graphics', e, o);
          ProcessTag('Names', e, o);
          ProcessTag('Stats', e, o);

          If ContainsStr('ACTI DOOR LIGH MGEF', sSignature) Then
            Begin
              ProcessTag('Sound', e, o);

              If sSignature = 'MGEF' Then
                ProcessTag('EffectStats', e, o);
            End;
        End;

      If ContainsStr('CREA EFSH GRAS LSCR LTEX REGN STAT TREE', sSignature) Then
        ProcessTag('Graphics', e, o);

      If sSignature = 'CONT' Then
        Begin
          ProcessTag('Invent.Add', e, o);
          ProcessTag('Invent.Change', e, o);
          ProcessTag('Invent.Remove', e, o);
          ProcessTag('Names', e, o);
          ProcessTag('Sound', e, o);
        End;

      If ContainsStr('DIAL ENCH EYES FACT HAIR QUST RACE SPEL WRLD', sSignature) Then
        Begin
          ProcessTag('Names', e, o);

          If sSignature = 'ENCH' Then
            ProcessTag('EnchantmentStats', e, o);

          If sSignature = 'SPEL' Then
            ProcessTag('SpellStats', e, o);
        End;

      If sSignature = 'FACT' Then
        Begin
          ProcessTag('Relations.Add', e, o);
          ProcessTag('Relations.Change', e, o);
          ProcessTag('Relations.Remove', e, o);
        End;

      If (sSignature = 'WTHR') Then
        ProcessTag('Sound', e, o);

      // special handling for CREA and NPC_
      If ContainsStr('CREA NPC_', sSignature) Then
        Begin
          If wbIsOblivion Or wbIsOblivionR Or wbIsFallout3 Or wbIsFalloutNV Or (sSignature = 'NPC_') Then
            ProcessTag('Actors.RecordFlags', e, o);

          If wbIsOblivion Or wbIsOblivionR Then
            Begin
              ProcessTag('Invent.Add', e, o);
              ProcessTag('Invent.Change', e, o);
              ProcessTag('Invent.Remove', e, o);
              ProcessTag('Names', e, o);

              If sSignature = 'CREA' Then
                ProcessTag('Sound', e, o);
            End;

          If Not (wbIsOblivion Or wbIsOblivionR) Then
            Begin
              g_Tag := 'Invent.Add';
              If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Inventory', False, False) Then
                ProcessTag(g_Tag, e, o);

              g_Tag := 'Invent.Change';
              If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Inventory', False, False) Then
                ProcessTag(g_Tag, e, o);

              g_Tag := 'Invent.Remove';
              If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Inventory', False, False) Then
                ProcessTag(g_Tag, e, o);

              // special handling for CREA and NPC_ record types
              g_Tag := 'Names';
              If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Base Data', False, False) Then
                ProcessTag(g_Tag, e, o);

              // special handling for CREA record type
              g_Tag := 'Sound';
              If sSignature = 'CREA' Then
                If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Use Model/Animation', False, False) Then
                  ProcessTag(g_Tag, e, o);
            End;
        End;
    End;

  // -------------------------------------------------------------------------------
  // GROUP: Fallout 4 (Wrye Bash patcher coverage)
  // -------------------------------------------------------------------------------
  If wbIsFallout4 Then
    Begin
      If sSignature = 'NPC_' Then
        Begin
          g_Tag := 'Actors.ACBS';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Stats', False, False) Then
            ProcessTag('Actors.ACBS', e, o);

          g_Tag := 'Actors.AIData';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'AI Data', False, False) Then
            ProcessTag('Actors.AIData', e, o);

          g_Tag := 'Actors.AIPackages';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'AI Packages', False, False) Then
            ProcessTag('Actors.AIPackages', e, o);

          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Traits', False, False) Then
            Begin
              ProcessTag('Actors.CombatStyle', e, o);
              ProcessTag('Actors.DeathItem', e, o);
            End;

          g_Tag := 'Actors.Stats';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Stats', False, False) Then
            ProcessTag('Actors.Stats', e, o);

          ProcessTag('Actors.Voice', e, o);
          ProcessTag('Actors.RecordFlags', e, o);

          g_Tag := 'NPC.Class';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Traits', False, False) Then
            ProcessTag('NPC.Class', e, o);

          g_Tag := 'NPC.Race';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Traits', False, False) Then
            ProcessTag('NPC.Race', e, o);

          ProcessTag('NPC.Perks.Add', e, o);
          ProcessTag('NPC.Perks.Change', e, o);
          ProcessTag('NPC.Perks.Remove', e, o);

          g_Tag := 'Actors.Factions';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Factions', False, False) Then
            ProcessTag('Actors.Factions', e, o);

          g_Tag := 'NPC.AIPackageOverrides';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'AI Packages', False, False) Then
            ProcessTag('NPC.AIPackageOverrides', e, o);

          ProcessTag('NPC.AttackRace', e, o);
          ProcessTag('NPC.CrimeFaction', e, o);
          ProcessTag('NPC.DefaultOutfit', e, o);

          g_Tag := 'Invent.Add';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Inventory', False, False) Then
            ProcessTag(g_Tag, e, o);

          g_Tag := 'Invent.Change';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Inventory', False, False) Then
            ProcessTag(g_Tag, e, o);

          g_Tag := 'Invent.Remove';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Inventory', False, False) Then
            ProcessTag(g_Tag, e, o);

          g_Tag := 'Names';
          If Not CompareFlags(e, o, 'ACBS\Template Flags', 'Base Data', False, False) Then
            ProcessTag(g_Tag, e, o);

          ProcessTag('Actors.Spells', e, o);
        End;

      If ContainsStr('ACTI ALCH AMMO ARMO ARTO BOOK CONT DOOR FLOR FURN IDLM INGR KEYM LCTN LIGH MGEF MISC MSTT NPC_ SPEL', sSignature) Then
        ProcessTag('Keywords', e, o);

      If ContainsStr('AACT ACTI ALCH AMMO ARMO AVIF BOOK CLAS CLFM CMPO CONT DOOR ENCH EXPL FACT FLOR FLST FURN HAZD HDPT INGR KEYM KYWD LIGH MESG MGEF MISC MSTT NOTE NPC_ OMOD PERK PROJ SCOL SNCT SPEL STAT', sSignature) Then
        ProcessTag('Names', e, o);

      If ContainsStr('ACTI ALCH AMMO ARMO BOOK CONT DOOR FLOR FURN INGR KEYM LIGH MISC MSTT NPC_ PROJ', sSignature) Then
        ProcessTag('Destructible', e, o);

      If sSignature = 'CONT' Then
        Begin
          ProcessTag('Invent.Add', e, o);
          ProcessTag('Invent.Change', e, o);
          ProcessTag('Invent.Remove', e, o);
        End;

      If sSignature = 'FURN' Then
        Begin
          ProcessTag('Invent.Add', e, o);
          ProcessTag('Invent.Change', e, o);
          ProcessTag('Invent.Remove', e, o);
        End;

      If sSignature = 'FACT' Then
        Begin
          ProcessTag('Relations.Add', e, o);
          ProcessTag('Relations.Change', e, o);
          ProcessTag('Relations.Remove', e, o);
        End;

      If sSignature = 'OTFT' Then
        Begin
          ProcessTag('Outfits.Add', e, o);
          ProcessTag('Outfits.Remove', e, o);
        End;

      If sSignature = 'FLST' Then
        ProcessTag('Deflst', e, o);

      If sSignature = 'MGEF' Then
        ProcessTag('EffectStats', e, o);

      If sSignature = 'ENCH' Then
        ProcessTag('EnchantmentStats', e, o);

      If ContainsStr('ARMO EXPL', sSignature) Then
        Begin
          ProcessTag('Enchantments', e, o);
          ProcessTag('Names', e, o);
        End;

      If ContainsStr('LVLI LVLN LVSP', sSignature) Then
        ProcessDelevRelevTags(e, o);
    End;

  // ObjectBounds
  g_Tag := 'ObjectBounds';

  If wbIsFallout3 And ContainsStr('ACTI ADDN ALCH AMMO ARMA ARMO ASPC BOOK COBJ CONT CREA DOOR EXPL FURN GRAS IDLM INGR KEYM LIGH LVLC LVLI LVLN MISC MSTT NOTE NPC_ PROJ PWAT SCOL SOUN STAT TACT TERM TREE TXST WEAP', sSignature) Then
    ProcessTag(g_Tag, e, o);

  If wbIsFalloutNV And ContainsStr('ACTI ADDN ALCH AMMO ARMA ARMO ASPC BOOK CCRD CHIP CMNY COBJ CONT CREA DOOR EXPL FURN GRAS IDLM IMOD INGR KEYM LIGH LVLC LVLI LVLN MISC MSTT NOTE NPC_ PROJ PWAT SCOL SOUN STAT TACT TERM TREE TXST WEAP', sSignature) Then
    ProcessTag(g_Tag, e, o);

  If wbIsSkyrim And ContainsStr('ACTI ADDN ALCH AMMO APPA ARMO ARTO ASPC BOOK CONT DOOR DUAL ENCH EXPL FLOR FURN GRAS HAZD IDLM INGR KEYM LIGH LVLI LVLN LVSP MISC MSTT NPC_ PROJ SCRL SLGM SOUN SPEL STAT TACT TREE TXST WEAP', sSignature) Then
    ProcessTag(g_Tag, e, o);

  If wbIsFallout4 And ContainsStr('ACTI ADDN ALCH AMMO ARMO ARTO ASPC BOOK CMPO CONT DOOR ENCH EXPL FLOR FURN GRAS HAZD IDLM INGR KEYM LIGH LVLI LVLN LVSP MISC MSTT NOTE NPC_ PKIN PROJ SCOL SOUN SPEL STAT', sSignature) Then
    ProcessTag(g_Tag, e, o);

  // Text
  If Not wbIsFallout4 Then
    Begin
      g_Tag := 'Text';

      If wbIsOblivion Or wbIsOblivionR And ContainsStr('BOOK BSGN CLAS LSCR MGEF SKIL', sSignature) Then
        ProcessTag(g_Tag, e, o);

      If wbIsFallout3 And ContainsStr('AVIF BOOK CLAS LSCR MESG MGEF NOTE PERK TERM', sSignature) Then
        ProcessTag(g_Tag, e, o);

      If wbIsFalloutNV And ContainsStr('AVIF BOOK CHAL CLAS IMOD LSCR MESG MGEF NOTE PERK TERM', sSignature) Then
        ProcessTag(g_Tag, e, o);

      If wbIsSkyrim And ContainsStr('ALCH AMMO APPA ARMO AVIF BOOK CLAS LSCR MESG MGEF SCRL SHOU SPEL WEAP', sSignature) Then
        ProcessTag(g_Tag, e, o);
    End;

  // Heuristic Force* tags (opt-in; runs after all other detection so it can read TagExists state).
  ProcessForceTagHeuristics(e, o);

  Finally
    g_DebugCurrentRecord := Nil;
  End;
End;


Function Finalize: integer;
Var
  bSavedOK   : boolean;
  sSaveError : string;
Begin
  Result := 0;

  // Flush the debug trace BEFORE freeing other lists, so even if a Free
  // raises (or anything else goes wrong below) we still write the trace
  // and announce the path to the Messages tab.
  bSavedOK   := False;
  sSaveError := '';
  If g_DebugLogReady Then
    Begin
      Try
        g_DebugLog.Add('');
        g_DebugLog.Add('# end of trace ' + DateTimeToStr(Now));
        g_DebugLog.SaveToFile(g_DebugLogPath);
        bSavedOK := True;
      Except
        on E: Exception Do
          sSaveError := '[' + E.ClassName + ': ' + E.Message + ']';
      End;
      Try g_DebugLog.Free; Except End;
      g_DebugLogReady := False;
    End
  Else
    sSaveError := '(buffer was never initialized - see warning above)';

  // Always announce the path, even if save failed - that way the user
  // knows where to look (or where it was supposed to land), and *why*.
  AddMessage('');
  AddMessage('================================================================================');
  If bSavedOK And FileExists(g_DebugLogPath) Then
    Begin
      AddMessage('Debug trace written to:');
      AddMessage('  ' + g_DebugLogPath);
    End
  Else
    Begin
      AddMessage('Debug trace was NOT written. Intended path was:');
      AddMessage('  ' + g_DebugLogPath);
      If sSaveError <> '' Then
        AddMessage('Reason: ' + sSaveError);
    End;
  AddMessage('================================================================================');

  Try slLog.Free;              Except End;
  Try slTagRelationships.Free; Except End;
  Try slSuggestedTags.Free;    Except End;
  Try slExistingTags.Free;     Except End;
  Try slDifferentTags.Free;    Except End;
  Try slBadTags.Free;          Except End;
  Try slDeprecatedTags.Free;   Except End;
  Try slOutToFileTags.Free;    Except End;
End;


Function StrToBool(AValue: String): boolean;
Begin
  If (AValue <> '0') And (AValue <> '1') Then
    Result := False
  Else
    Result := (AValue = '1');
End;


Function RegExMatchGroup(AExpr: String; ASubj: String; AGroup: integer): string;

Var 
  re     : TPerlRegEx;
Begin
  Result := '';
  re := TPerlRegEx.Create;
  Try
    re.RegEx := AExpr;
    re.Options := [];
    re.Subject := ASubj;
    If re.Match Then
      Result := re.Groups[AGroup];
  Finally
    re.Free;
End;
End;


Function RegExReplace(Const AExpr: String; ARepl: String; ASubj: String): string;

Var 
  re      : TPerlRegEx;
  sResult : string;
Begin
  Result := '';
  re := TPerlRegEx.Create;
  Try
    re.RegEx := AExpr;
    re.Options := [];
    re.Subject := ASubj;
    re.Replacement := ARepl;
    re.ReplaceAll;
    sResult := re.Subject;
  Finally
    re.Free;
    Result := sResult;
End;
End;


Function EditValues(Const AElement: IwbElement): string;

Var 
  kElement : IInterface;
  sName    : string;
  i        : integer;
Begin
  Result := GetEditValue(AElement);

  For i := 0 To Pred(ElementCount(AElement)) Do
    Begin
      kElement := ElementByIndex(AElement, i);
      sName    := Name(kElement);

      If SameText(sName, 'unknown') Or SameText(sName, 'unused') Then
        Continue;

      If Result <> '' Then
        Result := Result + ' ' + EditValues(kElement)
      Else
        Result := EditValues(kElement);
    End;
End;


Function CompareAssignment(AElement: IwbElement; AMaster: IwbElement): boolean;
Begin
  Result := False;

  DbgLog(DBG_PER_COMPARE, Format('CompareAssignment: tag=%s e=%s m=%s',
    [g_Tag, IfThen(Assigned(AElement), 'assigned', 'nil'), IfThen(Assigned(AMaster), 'assigned', 'nil')]));

  If TagExists(g_Tag) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> SKIP (tag already suggested earlier)');
      Exit;
    End;

  If Not Assigned(AElement) And Not Assigned(AMaster) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> NO-OP (both sides nil)');
      Exit;
    End;

  If Assigned(AElement) And Assigned(AMaster) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> NO-OP (both sides assigned; needs deeper compare)');
      Exit;
    End;

  AddLogEntry('Assigned', AElement, AMaster);
  slSuggestedTags.Add(g_Tag);
  DbgLog(DBG_PER_COMPARE, Format('  -> SUGGEST %s (assignment mismatch: only %s side assigned)',
    [g_Tag, IfThen(Assigned(AElement), 'override', 'master')]));

  Result := True;
End;


Function CompareElementCount(AElement: IwbElement; AMaster: IwbElement): boolean;
Begin
  Result := False;

  DbgLog(DBG_PER_COMPARE, Format('CompareElementCount: tag=%s e=%s m=%s',
    [g_Tag, IntToStr(ElementCount(AElement)), IntToStr(ElementCount(AMaster))]));

  If TagExists(g_Tag) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> SKIP (tag already suggested earlier)');
      Exit;
    End;

  If ElementCount(AElement) = ElementCount(AMaster) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> NO-OP (counts equal)');
      Exit;
    End;

  AddLogEntry('ElementCount', AElement, AMaster);
  slSuggestedTags.Add(g_Tag);
  DbgLog(DBG_PER_COMPARE, Format('  -> SUGGEST %s (count differs: %s vs %s)',
    [g_Tag, IntToStr(ElementCount(AElement)), IntToStr(ElementCount(AMaster))]));

  Result := True;
End;


Function CompareElementCountAdd(AElement: IwbElement; AMaster: IwbElement): boolean;
Begin
  Result := False;

  DbgLog(DBG_PER_COMPARE, Format('CompareElementCountAdd: tag=%s e=%s m=%s',
    [g_Tag, IntToStr(ElementCount(AElement)), IntToStr(ElementCount(AMaster))]));

  If TagExists(g_Tag) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> SKIP (tag already suggested earlier)');
      Exit;
    End;

  If ElementCount(AElement) <= ElementCount(AMaster) Then
    Begin
      DbgLog(DBG_PER_COMPARE, Format('  -> NO-OP (override count %s <= master count %s, no add)',
        [IntToStr(ElementCount(AElement)), IntToStr(ElementCount(AMaster))]));
      Exit;
    End;

  AddLogEntry('ElementCountAdd', AElement, AMaster);
  slSuggestedTags.Add(g_Tag);
  DbgLog(DBG_PER_COMPARE, Format('  -> SUGGEST %s (override has %s entries vs master %s -> additions present)',
    [g_Tag, IntToStr(ElementCount(AElement)), IntToStr(ElementCount(AMaster))]));

  Result := True;
End;


Function CompareElementCountRemove(AElement: IwbElement; AMaster: IwbElement): boolean;
Begin
  Result := False;

  DbgLog(DBG_PER_COMPARE, Format('CompareElementCountRemove: tag=%s e=%s m=%s',
    [g_Tag, IntToStr(ElementCount(AElement)), IntToStr(ElementCount(AMaster))]));

  If TagExists(g_Tag) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> SKIP (tag already suggested earlier)');
      Exit;
    End;

  If ElementCount(AElement) >= ElementCount(AMaster) Then
    Begin
      DbgLog(DBG_PER_COMPARE, Format('  -> NO-OP (override count %s >= master count %s, no removal)',
        [IntToStr(ElementCount(AElement)), IntToStr(ElementCount(AMaster))]));
      Exit;
    End;

  AddLogEntry('ElementCountRemove', AElement, AMaster);
  slSuggestedTags.Add(g_Tag);
  DbgLog(DBG_PER_COMPARE, Format('  -> SUGGEST %s (override has %s entries vs master %s -> removals present)',
    [g_Tag, IntToStr(ElementCount(AElement)), IntToStr(ElementCount(AMaster))]));

  Result := True;
End;


Function CompareEditValue(AElement: IwbElement; AMaster: IwbElement): boolean;
Var
  sE, sM : string;
Begin
  Result := False;

  sE := DbgEdv(AElement);
  sM := DbgEdv(AMaster);
  DbgLog(DBG_PER_COMPARE, Format('CompareEditValue: tag=%s path=%s', [g_Tag, DbgPath(AElement)]));

  If TagExists(g_Tag) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> SKIP (tag already suggested earlier)');
      Exit;
    End;

  If SameText(GetEditValue(AElement), GetEditValue(AMaster)) Then
    Begin
      DbgLog(DBG_PER_COMPARE, Format('  -> NO-OP (edit values equal: "%s")', [sE]));
      Exit;
    End;

  AddLogEntry('GetEditValue', AElement, AMaster);
  slSuggestedTags.Add(g_Tag);
  DbgLog(DBG_PER_COMPARE, Format('  -> SUGGEST %s (edit values differ)', [g_Tag]));
  DbgLog(DBG_LEAF_DIFFS, Format('       override="%s"  master="%s"', [sE, sM]));

  Result := True;
End;


Function CompareFlags(AElement: IwbElement; AMaster: IwbElement; APath: String; AFlagName: String; ASuggest: boolean; ANotOperator: boolean): boolean;

Var 
  x         : IwbElement;
  y         : IwbElement;
  a         : IwbElement;
  b         : IwbElement;
  sa        : string;
  sb        : string;
  sTestName : string;
  bResult   : boolean;
Begin
  Result := False;

  If TagExists(g_Tag) Then
    Begin
      DbgLog(DBG_PER_COMPARE, Format('CompareFlags: tag=%s path=%s flag=%s -> SKIP (tag already suggested)',
        [g_Tag, APath, AFlagName]));
      Exit;
    End;

  // flags arrays
  x := ElementByPath(AElement, APath);
  y := ElementByPath(AMaster, APath);

  // individual flags
  a := ElementByName(x, AFlagName);
  b := ElementByName(y, AFlagName);

  // individual flag edit values
  sa := GetEditValue(a);
  sb := GetEditValue(b);

  If ANotOperator Then
    Result := Not SameText(sa, sb)  // only used for Behave Like Exterior, Use Sky Lighting, and Has Water
  Else
    Result := StrToBool(sa) Or StrToBool(sb);

  DbgLog(DBG_PER_COMPARE, Format('CompareFlags: tag=%s path=%s flag="%s" op=%s e="%s" m="%s" -> %s',
    [g_Tag, APath, AFlagName, IfThen(ANotOperator, 'NOT', 'OR'), sa, sb,
     IfThen(Result, 'TRUE (gate fired)', 'FALSE (gate did not fire)')]));

  If ASuggest And Result Then
    Begin
      sTestName := IfThen(ANotOperator, 'CompareFlags:NOT', 'CompareFlags:OR');
      AddLogEntry(sTestName, x, y);
      slSuggestedTags.Add(g_Tag);
      DbgLog(DBG_PER_COMPARE, Format('  -> SUGGEST %s (CompareFlags suggest=true and gate fired)', [g_Tag]));
    End;
End;


Function CompareKeys(AElement: IwbElement; AMaster: IwbElement): boolean;

Var 
  sElementEditValues : string;
  sMasterEditValues  : string;
  ConflictState      : TConflictThis;
Begin
  Result := False;

  DbgLog(DBG_PER_COMPARE, Format('CompareKeys: tag=%s path=%s', [g_Tag, DbgPath(AElement)]));

  If TagExists(g_Tag) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> SKIP (tag already suggested earlier)');
      Exit;
    End;

  ConflictState := ConflictAllForMainRecord(ContainingMainRecord(AElement));

  If (ConflictState = caUnknown)
     Or (ConflictState = caOnlyOne)
     Or (ConflictState = caNoConflict) Then
    Begin
      DbgLog(DBG_PER_COMPARE, Format('  -> SKIP (conflict state %s; CompareKeys requires real cross-plugin conflict)',
        [DbgConflictName(ConflictState)]));
      Exit;
    End;

  sElementEditValues := EditValues(AElement);
  sMasterEditValues  := EditValues(AMaster);

  If IsEmptyKey(sElementEditValues) And IsEmptyKey(sMasterEditValues) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> NO-OP (both keys empty/zeroed)');
      Exit;
    End;

  If SameText(sElementEditValues, sMasterEditValues) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> NO-OP (serialized contents identical)');
      DbgLog(DBG_LEAF_DIFFS,  Format('       both="%s"', [DbgShortVal(sElementEditValues)]));
      Exit;
    End;

  AddLogEntry('CompareKeys', AElement, AMaster);
  slSuggestedTags.Add(g_Tag);
  DbgLog(DBG_PER_COMPARE, Format('  -> SUGGEST %s (serialized contents differ)', [g_Tag]));
  DbgLog(DBG_LEAF_DIFFS,  Format('       override="%s"', [DbgShortVal(sElementEditValues)]));
  DbgLog(DBG_LEAF_DIFFS,  Format('       master  ="%s"', [DbgShortVal(sMasterEditValues)]));

  Result := True;
End;


Function CompareNativeValues(AElement: IwbElement; AMaster: IwbElement; APath: String): boolean;

Var 
  x : IwbElement;
  y : IwbElement;
Begin
  Result := False;

  DbgLog(DBG_PER_COMPARE, Format('CompareNativeValues: tag=%s path=%s', [g_Tag, APath]));

  If TagExists(g_Tag) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> SKIP (tag already suggested earlier)');
      Exit;
    End;

  x := ElementByPath(AElement, APath);
  y := ElementByPath(AMaster, APath);

  If GetNativeValue(x) = GetNativeValue(y) Then
    Begin
      // GetNativeValue returns a Variant; the script engine won't coerce it
      // to Integer/String, so do not embed the value itself in the log.
      DbgLog(DBG_PER_COMPARE, Format('  -> NO-OP (native values equal at path "%s")', [APath]));
      DbgLog(DBG_LEAF_DIFFS,  Format('       edit-value="%s"', [DbgEdv(x)]));
      Exit;
    End;

  AddLogEntry('CompareNativeValues', AElement, AMaster);
  slSuggestedTags.Add(g_Tag);
  DbgLog(DBG_PER_COMPARE, Format('  -> SUGGEST %s (native values differ at path "%s")', [g_Tag, APath]));
  DbgLog(DBG_LEAF_DIFFS,  Format('       override="%s"  master="%s"', [DbgEdv(x), DbgEdv(y)]));

  Result := True;
End;


Function SortedArrayElementByValue(AElement: IwbElement; APath: String; AValue: String): IwbElement;

Var 
  i      : integer;
  kEntry : IwbElement;
Begin
  Result := Nil;
  For i := 0 To Pred(ElementCount(AElement)) Do
    Begin
      kEntry := ElementByIndex(AElement, i);
      If SameText(GetElementEditValues(kEntry, APath), AValue) Then
        Begin
          Result := kEntry;
          Exit;
        End;
    End;
End;


// TODO: natively implemented in 4.1.4
Procedure StringListDifference(ASet: TStringList; AOtherSet: TStringList; AOutput: TStringList);

Var 
  i : integer;
Begin
  For i := 0 To Pred(ASet.Count) Do
    If AOtherSet.IndexOf(ASet[i]) = -1 Then
      AOutput.Add(ASet[i]);
End;


// TODO: natively implemented in 4.1.4
Procedure StringListIntersection(ASet: TStringList; AOtherSet: TStringList; AOutput: TStringList);

Var 
  i : integer;
Begin
  For i := 0 To Pred(ASet.Count) Do
    If AOtherSet.IndexOf(ASet[i]) > -1 Then
      AOutput.Add(ASet[i]);
End;


// TODO: speed this up!
Function IsEmptyKey(AEditValues: String): boolean;

Var 
  i : integer;
Begin
  Result := True;
  For i := 1 To Length(AEditValues) Do
    If AEditValues[i] = '1' Then
      Begin
        Result := False;
        Exit;
      End;
End;


Function FormatTags(ATags: TStringList; ASingular: String; APlural: String; ANull: String): string;
Begin
  If ATags.Count = 1 Then
    Result := IntToStr(ATags.Count) + ' ' + ASingular + #13#10#32#32#32#32#32#32
  Else
    If ATags.Count > 1 Then
      Result := IntToStr(ATags.Count) + ' ' + APlural + #13#10#32#32#32#32#32#32;

  If ATags.Count > 0 Then
    Result := Result + Format(' {{BASH:%s}}', [ATags.DelimitedText])
  Else
    Result := ANull;
End;


Function TagExists(ATag: String): boolean;
Begin
  Result := (slSuggestedTags.IndexOf(ATag) <> -1);
End;


Procedure Evaluate(AElement: IwbElement; AMaster: IwbElement);
Begin
  DbgLog(DBG_PER_COMPARE, Format('Evaluate: tag=%s path=%s (-> Assignment, ElementCount, EditValue, Keys)',
    [g_Tag, DbgPath(AElement)]));

  // exit if the tag already exists
  If TagExists(g_Tag) Then
    Exit;

  // Suggest tag if one element exists while the other does not
  If CompareAssignment(AElement, AMaster) Then
    Exit;

  // exit if the first element does not exist
  If Not Assigned(AElement) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  Evaluate: override side nil; further checks skipped');
      Exit;
    End;

  // suggest tag if the two elements are different
  If CompareElementCount(AElement, AMaster) Then
    Exit;

  // suggest tag if the edit values of the two elements are different
  If CompareEditValue(AElement, AMaster) Then
    Exit;

  // compare any number of elements with CompareKeys
  If CompareKeys(AElement, AMaster) Then
    Exit;
End;


Procedure EvaluateAdd(AElement: IwbElement; AMaster: IwbElement);
Begin
  DbgLog(DBG_PER_COMPARE, Format('EvaluateAdd: tag=%s path=%s', [g_Tag, DbgPath(AElement)]));
  If TagExists(g_Tag) Then
    Exit;

  If Not Assigned(AElement) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  EvaluateAdd: override side nil; nothing to add-check');
      Exit;
    End;

  If CompareElementCountAdd(AElement, AMaster) Then
    Exit;
End;


Procedure EvaluateChange(AElement: IwbElement; AMaster: IwbElement);
Begin
  DbgLog(DBG_PER_COMPARE, Format('EvaluateChange: tag=%s path=%s', [g_Tag, DbgPath(AElement)]));
  If TagExists(g_Tag) Then
    Exit;

  If Not Assigned(AElement) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  EvaluateChange: override side nil; nothing to change-check');
      Exit;
    End;

  If CompareKeys(AElement, AMaster) Then
    Exit;
End;


Procedure EvaluateRemove(AElement: IwbElement; AMaster: IwbElement);
Begin
  DbgLog(DBG_PER_COMPARE, Format('EvaluateRemove: tag=%s path=%s', [g_Tag, DbgPath(AElement)]));
  If TagExists(g_Tag) Then
    Exit;

  If Not Assigned(AElement) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  EvaluateRemove: override side nil; nothing to remove-check');
      Exit;
    End;

  If CompareElementCountRemove(AElement, AMaster) Then
    Exit;
End;


Procedure EvaluateByPath(AElement: IwbElement; AMaster: IwbElement; APath: String);

Var 
  x : IInterface;
  y : IInterface;
Begin
  DbgLog(DBG_PER_COMPARE, Format('EvaluateByPath: tag=%s path="%s"', [g_Tag, APath]));
  x := ElementByPath(AElement, APath);
  y := ElementByPath(AMaster, APath);

  Evaluate(x, y);
End;


Procedure EvaluateByPathAdd(AElement: IwbElement; AMaster: IwbElement; APath: String);

Var 
  x : IInterface;
  y : IInterface;
Begin
  DbgLog(DBG_PER_COMPARE, Format('EvaluateByPathAdd: tag=%s path="%s"', [g_Tag, APath]));
  x := ElementByPath(AElement, APath);
  y := ElementByPath(AMaster, APath);

  EvaluateAdd(x, y);
End;


Procedure EvaluateByPathChange(AElement: IwbElement; AMaster: IwbElement; APath: String);

Var 
  x : IInterface;
  y : IInterface;
Begin
  DbgLog(DBG_PER_COMPARE, Format('EvaluateByPathChange: tag=%s path="%s"', [g_Tag, APath]));
  x := ElementByPath(AElement, APath);
  y := ElementByPath(AMaster, APath);

  EvaluateChange(x, y);
End;


Procedure EvaluateByPathRemove(AElement: IwbElement; AMaster: IwbElement; APath: String);

Var 
  x : IInterface;
  y : IInterface;
Begin
  DbgLog(DBG_PER_COMPARE, Format('EvaluateByPathRemove: tag=%s path="%s"', [g_Tag, APath]));
  x := ElementByPath(AElement, APath);
  y := ElementByPath(AMaster, APath);

  EvaluateRemove(x, y);
End;


Procedure ProcessTag(ATag: String; e: IInterface; m: IInterface);

Var 
  x          : IInterface;
  y          : IInterface;
  a          : IInterface;
  b          : IInterface;
  j          : IInterface;
  k          : IInterface;
  sSignature : string;
Begin
  g_Tag             := ATag;
  g_DebugCurrentTag := ATag;
  DbgSuggestSnapshot;

  DbgLog(DBG_PER_TAG, Format('CONSIDER tag=%s on %s', [ATag, DbgRecordTag]));
  Inc(g_DebugIndent);

  Try
  If TagExists(g_Tag) Then
    Exit;

  sSignature := Signature(e);

  // Bookmark: Actors.ACBS
  If (g_Tag = 'Actors.ACBS') Then
    Begin
      x := ElementBySignature(e, 'ACBS');
      y := ElementBySignature(m, 'ACBS');

      If wbIsFallout4 And (sSignature = 'NPC_') Then
        Begin
          a := ElementByName(x, 'Flags');
          b := ElementByName(y, 'Flags');

          If Not CompareFlags(x, y, 'Template Flags', 'Stats', False, False) And CompareKeys(a, b) Then
            Exit;

          EvaluateByPath(x, y, 'Calc min level');
          EvaluateByPath(x, y, 'Calc max level');
          EvaluateByPath(x, y, 'Disposition Base');
          EvaluateByPath(x, y, 'Bleedout Override');
          EvaluateByPath(x, y, 'XP Value Offset');
        End
      Else
        Begin
          a := ElementByName(x, 'Flags');
          b := ElementByName(y, 'Flags');

          If wbIsOblivion Or wbIsOblivionR And CompareKeys(a, b) Then
            Exit;

          If Not wbIsOblivion And Not CompareFlags(x, y, 'Template Flags', 'Use Base Data', False, False) And CompareKeys(a, b) Then
            Exit;

          EvaluateByPath(x, y, 'Fatigue');
          EvaluateByPath(x, y, 'Level');
          EvaluateByPath(x, y, 'Calc min');
          EvaluateByPath(x, y, 'Calc max');
          EvaluateByPath(x, y, 'Speed Multiplier');
          EvaluateByPath(e, m, 'DATA\Base Health');

          If wbIsOblivion Or wbIsOblivionR Or Not CompareFlags(x, y, 'Template Flags', 'Use AI Data', False, False) Then
            EvaluateByPath(x, y, 'Barter gold');
        End;
    End

    // Bookmark: Actors.AIData
  Else If (g_Tag = 'Actors.AIData') Then
         Begin
           x := ElementBySignature(e, 'AIDT');
           y := ElementBySignature(m, 'AIDT');

           If wbIsFallout4 Then
             Begin
               EvaluateByPath(x, y, 'Aggression');
               EvaluateByPath(x, y, 'Confidence');
               EvaluateByPath(x, y, 'Energy Level');
               EvaluateByPath(x, y, 'Morality');
               EvaluateByPath(x, y, 'Mood');
               EvaluateByPath(x, y, 'Assistance');
               If CompareNativeValues(x, y, 'Aggro') Then
                 Exit;
               EvaluateByPath(x, y, 'No Slow Approach');
             End
           Else
             Begin
               EvaluateByPath(x, y, 'Aggression');
               EvaluateByPath(x, y, 'Confidence');
               EvaluateByPath(x, y, 'Energy level');
               EvaluateByPath(x, y, 'Responsibility');
               EvaluateByPath(x, y, 'Teaches');
               EvaluateByPath(x, y, 'Maximum training level');

               If CompareNativeValues(x, y, 'Buys/Sells and Services') Then
                 Exit;
             End;
         End

         // Bookmark: Actors.AIPackages
  Else If (g_Tag = 'Actors.AIPackages') Then
         EvaluateByPath(e, m, 'Packages')

         // Bookmark: Actors.Anims
  Else If (g_Tag = 'Actors.Anims') Then
         EvaluateByPath(e, m, 'KFFZ')

         // Bookmark: Actors.CombatStyle
  Else If (g_Tag = 'Actors.CombatStyle') Then
         EvaluateByPath(e, m, 'ZNAM')

         // Bookmark: Actors.DeathItem
  Else If (g_Tag = 'Actors.DeathItem') Then
         EvaluateByPath(e, m, 'INAM')

         // Bookmark: NPC.Perks.Add (TES5/SSE/FO4)
  Else If (g_Tag = 'NPC.Perks.Add') Then
         EvaluateByPathAdd(e, m, 'Perks')

         // Bookmark: NPC.Perks.Change
         // Match entries on Perk; only fire if a shared perk's Rank differs.
         // Adds/removes go to NPC.Perks.Add / NPC.Perks.Remove.
  Else If (g_Tag = 'NPC.Perks.Change') Then
         DiffSubrecordList(e, m, 'NPC.Perks.Change', 'Perks', 'Perk', 'Rank')

         // Bookmark: NPC.Perks.Remove
  Else If (g_Tag = 'NPC.Perks.Remove') Then
         EvaluateByPathRemove(e, m, 'Perks')

         // Bookmark: Actors.RecordFlags (!FO4)
  Else If (g_Tag = 'Actors.RecordFlags') Then
         EvaluateByPath(e, m, 'Record Header\Record Flags')

         // Bookmark: Actors.Skeleton
  Else If (g_Tag = 'Actors.Skeleton') Then
         Begin
           // assign Model elements
           x := ElementByName(e, 'Model');
           y := ElementByName(m, 'Model');

           // exit if the Model property does not exist in the control record
           If Not Assigned(x) Then
             Exit;

           // evaluate properties
           EvaluateByPath(x, y, 'MODL');
           EvaluateByPath(x, y, 'MODB');
           EvaluateByPath(x, y, 'MODT');
         End

         // Bookmark: Actors.Spells
         // SPLO array name varies by game: TES4 = 'Spells', everything else = 'Actor Effects'.
  Else If (g_Tag = 'Actors.Spells') Then
         If wbIsOblivion Or wbIsOblivionR Then
           EvaluateByPath(e, m, 'Spells')
         Else
           EvaluateByPath(e, m, 'Actor Effects')

         // Bookmark: Actors.Stats
  Else If (g_Tag = 'Actors.Stats') Then
         Begin
           If wbIsFallout4 And (sSignature = 'NPC_') Then
             EvaluateByPath(e, m, 'PRPS')
           Else
             Begin
               x := ElementBySignature(e, 'DATA');
               y := ElementBySignature(m, 'DATA');

               If sSignature = 'CREA' Then
                 Begin
                   EvaluateByPath(x, y, 'Health');
                   EvaluateByPath(x, y, 'Combat Skill');
                   EvaluateByPath(x, y, 'Magic Skill');
                   EvaluateByPath(x, y, 'Stealth Skill');
                   EvaluateByPath(x, y, 'Attributes');
                 End
               Else If sSignature = 'NPC_' Then
                      Begin
                        EvaluateByPath(x, y, 'Base Health');
                        EvaluateByPath(x, y, 'Attributes');
                        EvaluateByPath(e, m, 'DNAM\Skill Values');
                        EvaluateByPath(e, m, 'DNAM\Skill Offsets');
                      End;
             End;
         End

         // Bookmark: Actors.Voice (FO3, FNV, TES5, SSE)
  Else If (g_Tag = 'Actors.Voice') Then
         EvaluateByPath(e, m, 'VTCK')

         // Bookmark: C.Acoustic
  Else If (g_Tag = 'C.Acoustic') Then
         EvaluateByPath(e, m, 'XCAS')

         // Bookmark: C.Climate
  Else If (g_Tag = 'C.Climate') Then
         Begin
           // add tag if the Behave Like Exterior flag is set ine one record but not the other
           If CompareFlags(e, m, 'DATA', 'Behave Like Exterior', True, True) Then
             Exit;

           // evaluate additional property
           EvaluateByPath(e, m, 'XCCM');
         End

         // Bookmark: C.Encounter
  Else If (g_Tag = 'C.Encounter') Then
         EvaluateByPath(e, m, 'XEZN')

         // Bookmark: C.ForceHideLand (!TES4, !FO4)
  Else If (g_Tag = 'C.ForceHideLand') Then
         EvaluateByPath(e, m, 'XCLC\Land Flags')

         // Bookmark: C.ImageSpace
  Else If (g_Tag = 'C.ImageSpace') Then
         EvaluateByPath(e, m, 'XCIM')

         // Bookmark: C.Light
  Else If (g_Tag = 'C.Light') Then
         EvaluateByPath(e, m, 'XCLL')

         // Bookmark: C.Location
  Else If (g_Tag = 'C.Location') Then
         EvaluateByPath(e, m, 'XLCN')

         // Bookmark: C.LockList
  Else If (g_Tag = 'C.LockList') Then
         EvaluateByPath(e, m, 'XILL')

         // Bookmark: C.MiscFlags (!FO4)
  Else If (g_Tag = 'C.MiscFlags') Then
         Begin
           If CompareFlags(e, m, 'DATA', 'Is Interior Cell', True, True) Then
             Exit;

           If CompareFlags(e, m, 'DATA', 'Can Travel From Here', True, True) Then
             Exit;

           If Not wbIsOblivion Or wbIsOblivionR And Not wbIsFallout4 Then
             If CompareFlags(e, m, 'DATA', 'No LOD Water', True, True) Then
               Exit;

           If wbIsOblivion Or wbIsOblivionR Then
             If CompareFlags(e, m, 'DATA', 'Force hide land (exterior cell) / Oblivion interior (interior cell)', True, True) Then
               Exit;

           If CompareFlags(e, m, 'DATA', 'Hand Changed', True, True) Then
             Exit;
         End

         // Bookmark: C.Music
  Else If (g_Tag = 'C.Music') Then
         EvaluateByPath(e, m, 'XCMO')

         // Bookmark: FULL (C.Name, Names)
  Else If ContainsStr('C.Name Names', g_Tag) Then
         EvaluateByPath(e, m, 'FULL')

         // Bookmark: C.Owner
  Else If (g_Tag = 'C.Owner') Then
         EvaluateByPath(e, m, 'Ownership')

         // Bookmark: C.RecordFlags
  Else If (g_Tag = 'C.RecordFlags') Then
         EvaluateByPath(e, m, 'Record Header\Record Flags')

         // Bookmark: C.Regions
  Else If (g_Tag = 'C.Regions') Then
         EvaluateByPath(e, m, 'XCLR')

         // Bookmark: C.SkyLighting
         // add tag if the Behave Like Exterior flag is set in one record but not the other
  Else If (g_Tag = 'C.SkyLighting') And CompareFlags(e, m, 'DATA', 'Use Sky Lighting', True, True) Then
         Exit

         // Bookmark: C.Water
  Else If (g_Tag = 'C.Water') Then
         Begin
           // add tag if Has Water flag is set in one record but not the other
           If CompareFlags(e, m, 'DATA', 'Has Water', True, True) Then
             Exit;

           // exit if Is Interior Cell is set in either record
           If CompareFlags(e, m, 'DATA', 'Is Interior Cell', False, False) Then
             Exit;

           // evaluate properties
           EvaluateByPath(e, m, 'XCLW');
           EvaluateByPath(e, m, 'XCWT');
         End

         // Bookmark: Creatures.Blood
  Else If (g_Tag = 'Creatures.Blood') Then
         Begin
           EvaluateByPath(e, m, 'NAM0');
           EvaluateByPath(e, m, 'NAM1');
         End

         // Bookmark: Creatures.Type
  Else If (g_Tag = 'Creatures.Type') Then
         EvaluateByPath(e, m, 'DATA\Type')

         // Bookmark: Deflst
  Else If (g_Tag = 'Deflst') Then
         EvaluateByPathRemove(e, m, 'FormIDs')

         // Bookmark: Destructible
  Else If (g_Tag = 'Destructible') Then
         Begin
           // assign Destructable elements
           x := ElementByName(e, 'Destructible');
           y := ElementByName(m, 'Destructible');

           If CompareAssignment(x, y) Then
             Exit;

           a := ElementBySignature(x, 'DEST');
           b := ElementBySignature(y, 'DEST');

           // evaluate Destructable properties
           EvaluateByPath(a, b, 'Health');
           EvaluateByPath(a, b, 'Count');
           EvaluateByPath(x, y, 'Stages');

           // assign Destructable flags
           If Not wbIsSkyrim Then
             Begin
               j := ElementByName(a, 'Flags');
               k := ElementByName(b, 'Flags');

               If Assigned(j) Or Assigned(k) Then
                 Begin
                   // add tag if Destructable flags exist in one record
                   If CompareAssignment(j, k) Then
                     Exit;

                   // evaluate Destructable flags
                   If CompareKeys(j, k) Then
                     Exit;
                 End;
             End;
         End

         // Bookmark: EffectStats
  Else If (g_Tag = 'EffectStats') Then
         Begin
           If wbIsOblivion Or wbIsOblivionR Or wbIsFallout3 Or wbIsFalloutNV Then
             Begin
               EvaluateByPath(e, m, 'DATA\Flags');

               If Not wbIsFallout3 And Not wbIsFalloutNV Then
                 EvaluateByPath(e, m, 'DATA\Base cost');

               If Not wbIsOblivion Or wbIsOblivionR Then
                 EvaluateByPath(e, m, 'DATA\Associated Item');

               If Not wbIsFallout3 And Not wbIsFalloutNV Then
                 EvaluateByPath(e, m, 'DATA\Magic School');

               EvaluateByPath(e, m, 'DATA\Resist Value');
               EvaluateByPath(e, m, 'DATA\Projectile Speed');

               If Not wbIsFallout3 And Not wbIsFalloutNV Then
                 Begin
                   EvaluateByPath(e, m, 'DATA\Constant Effect enchantment factor');
                   EvaluateByPath(e, m, 'DATA\Constant Effect barter factor');
                 End;

               If wbIsOblivion Or wbIsOblivionR And CompareFlags(e, m, 'DATA\Flags', 'Use actor value', False, False) Then
                 EvaluateByPath(e, m, 'DATA\Assoc. Actor Value')
               Else If wbIsFallout3 Or wbIsFalloutNV Then
                      Begin
                        EvaluateByPath(e, m, 'DATA\Archtype');
                        EvaluateByPath(e, m, 'DATA\Actor Value');
                      End;
             End
           Else If wbIsSkyrim Or wbIsFallout4 Then
                  Begin
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Flags');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Base Cost');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Associated Item');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Magic Skill');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Resist Value');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Taper Weight');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Minimum Skill Level');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Spellmaking');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Taper Curve');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Taper Duration');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Second AV Weight');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Archtype');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Actor Value');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Casting Type');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Delivery');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Second Actor Value');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Skill Usage Multiplier');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Equip Ability');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Perk to Apply');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Script Effect AI');
                  End;
         End

         // Bookmark: EnchantmentStats
  Else If (g_Tag = 'EnchantmentStats') Then
         Begin
           If wbIsOblivion Or wbIsOblivionR Or wbIsFallout3 Or wbIsFalloutNV Then
             Begin
               EvaluateByPath(e, m, 'ENIT\Type');
               EvaluateByPath(e, m, 'ENIT\Charge Amount');
               EvaluateByPath(e, m, 'ENIT\Enchant Cost');
               EvaluateByPath(e, m, 'ENIT\Flags');
             End
           Else If wbIsSkyrim Or wbIsFallout4 Then
                  EvaluateByPath(e, m, 'ENIT');
         End

         // Bookmark: Actors.Factions
  Else If (g_Tag = 'Actors.Factions') Then
         Begin
           x := ElementByName(e, 'Factions');
           y := ElementByName(m, 'Factions');

           If CompareAssignment(x, y) Then
             Exit;

           If Not Assigned(x) Then
             Exit;

           If CompareKeys(x, y) Then
             Exit;
         End

         // Bookmark: Enchantments (FO4 ARMO/EXPL, etc.)
  Else If (g_Tag = 'Enchantments') Then
         EvaluateByPath(e, m, 'Enchantment')

         // Bookmark: Graphics
  Else If (g_Tag = 'Graphics') Then
         Begin
           // evaluate Icon and Model properties
           If ContainsStr('ALCH AMMO APPA BOOK INGR KEYM LIGH MGEF MISC SGST SLGM TREE WEAP', sSignature) Then
             Begin
               EvaluateByPath(e, m, 'Icon');
               EvaluateByPath(e, m, 'Model');
             End

             // evaluate Icon properties
           Else If ContainsStr('BSGN CLAS LSCR LTEX REGN', sSignature) Then
                  EvaluateByPath(e, m, 'Icon')

                  // evaluate Model properties
           Else If ContainsStr('ACTI DOOR FLOR FURN GRAS STAT', sSignature) Then
                  EvaluateByPath(e, m, 'Model')

                  // evaluate ARMO properties
           Else If sSignature = 'ARMO' Then
                  Begin
                    // Shared
                    EvaluateByPath(e, m, 'Male world model');
                    EvaluateByPath(e, m, 'Female world model');

                    // ARMO - Oblivion
                    If wbIsOblivion Or wbIsOblivionR Then
                      Begin
                        // evaluate Icon properties
                        EvaluateByPath(e, m, 'Icon');
                        EvaluateByPath(e, m, 'Icon 2 (female)');

                        // assign First Person Flags elements
                        x := ElementByPath(e, 'BODT\First Person Flags');
                        If Not Assigned(x) Then
                          Exit;

                        y := ElementByPath(m, 'BODT\First Person Flags');

                        // evaluate First Person Flags
                        If CompareKeys(x, y) Then
                          Exit;

                        // assign General Flags elements
                        x := ElementByPath(e, 'BODT\General Flags');
                        If Not Assigned(x) Then
                          Exit;

                        y := ElementByPath(m, 'BODT\General Flags');

                        // evaluate General Flags
                        If CompareKeys(x, y) Then
                          Exit;
                      End

                      // ARMO - FO3, FNV
                    Else If wbIsFallout3 Or wbIsFalloutNV Then
                           Begin
                             // evaluate Icon properties
                             EvaluateByPath(e, m, 'ICON');
                             EvaluateByPath(e, m, 'ICO2');

                             // assign First Person Flags elements
                             x := ElementByPath(e, 'BMDT\Biped Flags');
                             If Not Assigned(x) Then
                               Exit;

                             y := ElementByPath(m, 'BMDT\Biped Flags');

                             // evaluate First Person Flags
                             If CompareKeys(x, y) Then
                               Exit;

                             // assign General Flags elements
                             x := ElementByPath(e, 'BMDT\General Flags');
                             If Not Assigned(x) Then
                               Exit;

                             y := ElementByPath(m, 'BMDT\General Flags');

                             // evaluate General Flags
                             If CompareKeys(x, y) Then
                               Exit;
                           End

                           // ARMO - TES5
                    Else If wbIsSkyrim Then
                           Begin
                             // evaluate Icon properties
                             EvaluateByPath(e, m, 'Icon');
                             EvaluateByPath(e, m, 'Icon 2 (female)');

                             // evaluate Biped Model properties
                             EvaluateByPath(e, m, 'Male world model');
                             EvaluateByPath(e, m, 'Female world model');

                             // assign First Person Flags elements
                             x  := ElementByPath(e, 'BOD2\First Person Flags');
                             If Not Assigned(x) Then
                               Exit;

                             y := ElementByPath(m, 'BOD2\First Person Flags');

                             // evaluate First Person Flags
                             If CompareKeys(x, y) Then
                               Exit;

                             // assign General Flags elements
                             x := ElementByPath(e, 'BOD2\General Flags');
                             If Not Assigned(x) Then
                               Exit;

                             y := ElementByPath(m, 'BOD2\General Flags');

                             // evaluate General Flags
                             If CompareKeys(x, y) Then
                               Exit;
                           End;
                  End

                  // evaluate CREA properties
           Else If sSignature = 'CREA' Then
                  Begin
                    EvaluateByPath(e, m, 'NIFZ');
                    EvaluateByPath(e, m, 'NIFT');
                  End

                  // evaluate EFSH properties
           Else If sSignature = 'EFSH' Then
                  Begin
                    // evaluate Record Flags
                    x := ElementByPath(e, 'Record Header\Record Flags');
                    y := ElementByPath(m, 'Record Header\Record Flags');

                    If CompareKeys(x, y) Then
                      Exit;

                    // evaluate Icon properties
                    EvaluateByPath(e, m, 'ICON');
                    EvaluateByPath(e, m, 'ICO2');

                    // evaluate other properties
                    EvaluateByPath(e, m, 'NAM7');

                    If wbIsSkyrim Then
                      Begin
                        EvaluateByPath(e, m, 'NAM8');
                        EvaluateByPath(e, m, 'NAM9');
                      End;

                    EvaluateByPath(e, m, 'DATA');
                  End

                  // evaluate MGEF properties
           Else If wbIsSkyrim And (sSignature = 'MGEF') Then
                  Begin
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Casting Light');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Hit Shader');
                    EvaluateByPath(e, m, 'Magic Effect Data\DATA\Enchant Shader');
                  End

                  // evaluate Material property
           Else If sSignature = 'STAT' Then
                  EvaluateByPath(e, m, 'DNAM\Material');
         End

         // Bookmark: Invent.Add
  Else If (g_Tag = 'Invent.Add') Then
         EvaluateByPathAdd(e, m, 'Items')

         // Bookmark: Invent.Change
         // Match entries on CNTO\Item; only fire if a shared item's count or extra data
         // (COED — owner/condition/health, FO3+ only) differs. Pure adds/removes are
         // handled by Invent.Add/Invent.Remove and must not pollute Invent.Change.
  Else If (g_Tag = 'Invent.Change') Then
         If wbIsOblivion Or wbIsOblivionR Then
           DiffSubrecordList(e, m, 'Invent.Change', 'Items', 'CNTO\Item', 'CNTO\Count')
         Else
           DiffSubrecordList(e, m, 'Invent.Change', 'Items', 'CNTO\Item', 'CNTO\Count|COED')

         // Bookmark: Invent.Remove
  Else If (g_Tag = 'Invent.Remove') Then
         EvaluateByPathRemove(e, m, 'Items')

         // Bookmark: Keywords
  Else If (g_Tag = 'Keywords') Then
         Begin
           x := ElementBySignature(e, 'KWDA');
           y := ElementBySignature(m, 'KWDA');

           If CompareAssignment(x, y) Then
             Exit;

           If CompareElementCount(x, y) Then
             Exit;

           x := ElementBySignature(e, 'KSIZ');
           y := ElementBySignature(m, 'KSIZ');

           If CompareAssignment(x, y) Then
             Exit;

           If CompareEditValue(x, y) Then
             Exit;
         End

         // Bookmark: NPC.AIPackageOverrides
  Else If (g_Tag = 'NPC.AIPackageOverrides') Then
         Begin
           If wbIsSkyrim Then
             Begin
               EvaluateByPath(e, m, 'SPOR');
               EvaluateByPath(e, m, 'OCOR');
               EvaluateByPath(e, m, 'GWOR');
               EvaluateByPath(e, m, 'ECOR');
             End;
         End

         // Bookmark: NPC.AttackRace
  Else If (g_Tag = 'NPC.AttackRace') Then
         EvaluateByPath(e, m, 'ATKR')

         // Bookmark: NPC.Class
  Else If (g_Tag = 'NPC.Class') Then
         EvaluateByPath(e, m, 'CNAM')

         // Bookmark: NPC.CrimeFaction
  Else If (g_Tag = 'NPC.CrimeFaction') Then
         EvaluateByPath(e, m, 'CRIF')

         // Bookmark: NPC.DefaultOutfit
  Else If (g_Tag = 'NPC.DefaultOutfit') Then
         EvaluateByPath(e, m, 'DOFT')

         // Bookmark: NPC.Eyes
  Else If (g_Tag = 'NPC.Eyes') Then
         EvaluateByPath(e, m, 'ENAM')

         // Bookmark: NPC.FaceGen
  Else If (g_Tag = 'NPC.FaceGen') Then
         EvaluateByPath(e, m, 'FaceGen Data')

         // Bookmark: NPC.Hair
  Else If (g_Tag = 'NPC.Hair') Then
         EvaluateByPath(e, m, 'HNAM')

         // Bookmark: NPC.Race
  Else If (g_Tag = 'NPC.Race') Then
         EvaluateByPath(e, m, 'RNAM')

         // Bookmark: ObjectBounds
  Else If (g_Tag = 'ObjectBounds') Then
         EvaluateByPath(e, m, 'OBND')

         // Bookmark: Outfits.Add
         // OTFT records expose a single child array element 'Items' (signature INAM).
         // The previous 'OTFT' path was the record signature itself, which never resolves.
  Else If (g_Tag = 'Outfits.Add') Then
         EvaluateByPathAdd(e, m, 'Items')

         // Bookmark: Outfits.Remove
  Else If (g_Tag = 'Outfits.Remove') Then
         EvaluateByPathRemove(e, m, 'Items')

         // Bookmark: R.AddSpells / R.ChangeSpells handled by ProcessRaceSpells (list-diff split)

         // Bookmark: R.Attributes-F
  Else If (g_Tag = 'R.Attributes-F') Then
         EvaluateByPath(e, m, 'ATTR\Female')

         // Bookmark: R.Attributes-M
  Else If (g_Tag = 'R.Attributes-M') Then
         EvaluateByPath(e, m, 'ATTR\Male')

         // Bookmark: R.Body-F
  Else If (g_Tag = 'R.Body-F') Then
         EvaluateByPath(e, m, 'Body Data\Female Body Data\Parts')

         // Bookmark: R.Body-M
  Else If (g_Tag = 'R.Body-M') Then
         EvaluateByPath(e, m, 'Body Data\Male Body Data\Parts')

         // Bookmark: R.Body-Size-F
  Else If (g_Tag = 'R.Body-Size-F') Then
         Begin
           EvaluateByPath(e, m, 'DATA\Female Height');
           EvaluateByPath(e, m, 'DATA\Female Weight');
         End

         // Bookmark: R.Body-Size-M
  Else If (g_Tag = 'R.Body-Size-M') Then
         Begin
           EvaluateByPath(e, m, 'DATA\Male Height');
           EvaluateByPath(e, m, 'DATA\Male Weight');
         End

         // Bookmark: R.ChangeSpells
         // RACE SPLO array name varies by game: TES4 = 'Spells', TES5/SSE/Enderal = 'Actor Effects'.
         // Normally reached via ProcessRaceSpells (which handles the Add/Change split itself);
         // this handler is defensive in case ProcessTag('R.ChangeSpells', ...) is called directly.
  Else If (g_Tag = 'R.ChangeSpells') Then
         If wbIsOblivion Or wbIsOblivionR Then
           EvaluateByPath(e, m, 'Spells')
         Else
           EvaluateByPath(e, m, 'Actor Effects')

         // Bookmark: R.Description
  Else If (g_Tag = 'R.Description') Then
         EvaluateByPath(e, m, 'DESC')

         // Bookmark: R.Ears
  Else If (g_Tag = 'R.Ears') Then
         Begin
           EvaluateByPath(e, m, 'Head Data\Male Head Data\Parts\[1]');
           EvaluateByPath(e, m, 'Head Data\Female Head Data\Parts\[1]');
         End

         // Bookmark: R.Eyes
  Else If (g_Tag = 'R.Eyes') Then
         EvaluateByPath(e, m, 'ENAM')

         // Bookmark: R.Hair
  Else If (g_Tag = 'R.Hair') Then
         EvaluateByPath(e, m, 'HNAM')

         // Bookmark: R.Head
  Else If (g_Tag = 'R.Head') Then
         Begin
           EvaluateByPath(e, m, 'Head Data\Male Head Data\Parts\[0]');
           EvaluateByPath(e, m, 'Head Data\Female Head Data\Parts\[0]');
           EvaluateByPath(e, m, 'FaceGen Data');
         End

         // Bookmark: R.Mouth
  Else If (g_Tag = 'R.Mouth') Then
         Begin
           EvaluateByPath(e, m, 'Head Data\Male Head Data\Parts\[2]');
           EvaluateByPath(e, m, 'Head Data\Female Head Data\Parts\[2]');
         End

         // Bookmark: R.Relations.Add
  Else If (g_Tag = 'R.Relations.Add') Then
         EvaluateByPathAdd(e, m, 'Relations')

         // Bookmark: R.Relations.Change
         // Match entries on Faction; only fire if a shared faction's Modifier or
         // (Skyrim/FO4) Group Combat Reaction differs. Adds/removes go to
         // R.Relations.Add / R.Relations.Remove.
  Else If (g_Tag = 'R.Relations.Change') Then
         If wbIsSkyrim Or wbIsFallout4 Then
           DiffSubrecordList(e, m, 'R.Relations.Change', 'Relations', 'Faction', 'Modifier|Group Combat Reaction')
         Else
           DiffSubrecordList(e, m, 'R.Relations.Change', 'Relations', 'Faction', 'Modifier')

         // Bookmark: R.Relations.Remove
  Else If (g_Tag = 'R.Relations.Remove') Then
         EvaluateByPathRemove(e, m, 'Relations')

         // Bookmark: R.Skills
  Else If (g_Tag = 'R.Skills') Then
         EvaluateByPath(e, m, 'DATA\Skill Boosts')

         // Bookmark: R.Teeth
  Else If (g_Tag = 'R.Teeth') Then
         Begin
           EvaluateByPath(e, m, 'Head Data\Male Head Data\Parts\[3]');
           EvaluateByPath(e, m, 'Head Data\Female Head Data\Parts\[3]');

           // FO3
           If wbIsFallout3 Then
             Begin
               EvaluateByPath(e, m, 'Head Data\Male Head Data\Parts\[4]');
               EvaluateByPath(e, m, 'Head Data\Female Head Data\Parts\[4]');
             End;
         End

         // Bookmark: R.Voice-F
  Else If (g_Tag = 'R.Voice-F') Then
         EvaluateByPath(e, m, 'VTCK\Voice #1 (Female)')

         // Bookmark: R.Voice-M
  Else If (g_Tag = 'R.Voice-M') Then
         EvaluateByPath(e, m, 'VTCK\Voice #0 (Male)')

         // Bookmark: Relations.Add
  Else If (g_Tag = 'Relations.Add') Then
         EvaluateByPathAdd(e, m, 'Relations')

         // Bookmark: Relations.Change
         // Match entries on Faction; only fire if a shared faction's Modifier or
         // (Skyrim/FO4) Group Combat Reaction differs. Adds/removes go to
         // Relations.Add / Relations.Remove.
  Else If (g_Tag = 'Relations.Change') Then
         If wbIsSkyrim Or wbIsFallout4 Then
           DiffSubrecordList(e, m, 'Relations.Change', 'Relations', 'Faction', 'Modifier|Group Combat Reaction')
         Else
           DiffSubrecordList(e, m, 'Relations.Change', 'Relations', 'Faction', 'Modifier')

         // Bookmark: Relations.Remove
  Else If (g_Tag = 'Relations.Remove') Then
         EvaluateByPathRemove(e, m, 'Relations')

         // Bookmark: Roads
  Else If (g_Tag = 'Roads') Then
         EvaluateByPath(e, m, 'PGRP')

         // Bookmark: Scripts
  Else If (g_Tag = 'Scripts') Then
         EvaluateByPath(e, m, 'SCRI')

         // Bookmark: Sound
  Else If (g_Tag = 'Sound') Then
         Begin
           // Activators, Containers, Doors, and Lights
           If ContainsStr('ACTI CONT DOOR LIGH', sSignature) Then
             Begin
               EvaluateByPath(e, m, 'SNAM');

               // Activators
               If sSignature = 'ACTI' Then
                 EvaluateByPath(e, m, 'VNAM')

                 // Containers
               Else If sSignature = 'CONT' Then
                      Begin
                        EvaluateByPath(e, m, 'QNAM');
                        If Not wbIsSkyrim And Not wbIsFallout3 Then
                          EvaluateByPath(e, m, 'RNAM');
                        // FO3, TESV, and SSE don't have this element
                      End

                      // Doors
               Else If sSignature = 'DOOR' Then
                      Begin
                        EvaluateByPath(e, m, 'ANAM');
                        EvaluateByPath(e, m, 'BNAM');
                      End;
             End

             // Creatures
           Else If sSignature = 'CREA' Then
                  Begin
                    EvaluateByPath(e, m, 'WNAM');
                    EvaluateByPath(e, m, 'CSCR');
                    EvaluateByPath(e, m, 'Sound Types');
                  End

                  // Magic Effects
           Else If sSignature = 'MGEF' Then
                  Begin
                    // TES5, SSE
                    If wbIsSkyrim Then
                      EvaluateByPath(e, m, 'SNDD')

                      // FO3, FNV, TES4
                    Else
                      Begin
                        EvaluateByPath(e, m, 'DATA\Effect sound');
                        EvaluateByPath(e, m, 'DATA\Bolt sound');
                        EvaluateByPath(e, m, 'DATA\Hit sound');
                        EvaluateByPath(e, m, 'DATA\Area sound');
                      End;
                  End

                  // Weather
           Else If sSignature = 'WTHR' Then
                  EvaluateByPath(e, m, 'Sounds');
         End

         // Bookmark: SpellStats
  Else If (g_Tag = 'SpellStats') Then
         EvaluateByPath(e, m, 'SPIT')

         // Bookmark: Stats
  Else If (g_Tag = 'Stats') Then
         Begin
           If ContainsStr('ALCH AMMO APPA ARMO BOOK CLOT INGR KEYM LIGH MISC SGST SLGM WEAP', sSignature) Then
             Begin
               EvaluateByPath(e, m, 'EDID');
               EvaluateByPath(e, m, 'DATA');

               If ContainsStr('ARMO WEAP', sSignature) Then
                 EvaluateByPath(e, m, 'DNAM')

               Else If sSignature = 'WEAP' Then
                      EvaluateByPath(e, m, 'CRDT');
             End

           Else If sSignature = 'ARMA' Then
                  EvaluateByPath(e, m, 'DNAM');
         End

         // Bookmark: Text
  Else If (g_Tag = 'Text') Then
         Begin
           If ContainsStr('ALCH AMMO APPA ARMO AVIF BOOK BSGN CHAL CLAS IMOD LSCR MESG MGEF PERK SCRL SHOU SKIL SPEL TERM WEAP', sSignature) Then
             EvaluateByPath(e, m, 'DESC')

           Else If Not wbIsOblivion Or wbIsOblivionR Then
                  Begin
                    If sSignature = 'BOOK' Then
                      EvaluateByPath(e, m, 'CNAM')

                    Else If sSignature = 'MGEF' Then
                           EvaluateByPath(e, m, 'DNAM')

                    Else If sSignature = 'NOTE' Then
                           EvaluateByPath(e, m, 'TNAM');
                  End;
         End

         // Bookmark: WeaponMods
  Else If (g_Tag = 'WeaponMods') Then
         EvaluateByPath(e, m, 'Weapon Mods');

  Finally
    Dec(g_DebugIndent);
    If DbgWasSuggested Then
      DbgLog(DBG_PER_TAG, Format('VERDICT tag=%s on %s -> SUGGESTED', [ATag, DbgRecordTag]))
    Else
      DbgLog(DBG_PER_TAG, Format('VERDICT tag=%s on %s -> NOT SUGGESTED', [ATag, DbgRecordTag]));
    g_DebugCurrentTag := '';
  End;
End;


Procedure ProcessDelevRelevTags(ARecord: IwbMainRecord; AMaster: IwbMainRecord);

Var 
  kEntries          : IwbElement;
  kEntriesMaster    : IwbElement;
  kEntry            : IwbElement;
  kEntryMaster      : IwbElement;
  kCOED             : IwbElement;
  // extra data
  kCOEDMaster       : IwbElement;
  // extra data
  sSignature        : string;
  sEditValues       : string;
  sMasterEditValues : string;
  i                 : integer;
  j                 : integer;
Begin
  // nothing to do if already tagged
  If TagExists('Delev') And TagExists('Relev') Then
    Exit;

  // get Leveled List Entries
  kEntries       := ElementByName(ARecord, 'Leveled List Entries');
  kEntriesMaster := ElementByName(AMaster, 'Leveled List Entries');

  If Not Assigned(kEntries) Then
    Exit;

  If Not Assigned(kEntriesMaster) Then
    Exit;

  // initalize count matched on reference entries
  j := 0;

  If Not TagExists('Relev') Then
    Begin
      g_Tag := 'Relev';

      For i := 0 To Pred(ElementCount(kEntries)) Do
        Begin
          kEntry := ElementByIndex(kEntries, i);
          kEntryMaster := SortedArrayElementByValue(kEntriesMaster, 'LVLO\Reference', GetElementEditValues(kEntry, 'LVLO\Reference'));

          If Not Assigned(kEntryMaster) Then
            Continue;

          Inc(j);

          If TagExists(g_Tag) Then
            Continue;

          If CompareNativeValues(kEntry, kEntryMaster, 'LVLO\Level') Then
            Exit;

          If CompareNativeValues(kEntry, kEntryMaster, 'LVLO\Count') Then
            Exit;

          If wbIsOblivion Or wbIsOblivionR Then
            Continue;

          // Relev check for changed level, count, extra data
          kCOED       := ElementBySignature(kEntry, 'COED');
          kCOEDMaster := ElementBySignature(kEntryMaster, 'COED');

          sEditValues       := EditValues(kCOED);
          sMasterEditValues := EditValues(kCOEDMaster);

          If Not SameText(sEditValues, sMasterEditValues) Then
            Begin
              AddLogEntry('Assigned', kCOED, kCOEDMaster);
              slSuggestedTags.Add(g_Tag);
              Exit;
            End;
        End;
    End;

  If Not TagExists('Delev') Then
    Begin
      g_Tag := 'Delev';

      sSignature := Signature(ARecord);

      If (((sSignature = 'LVLC') And (wbIsOblivion Or wbIsOblivionR Or wbIsFallout3 Or wbIsFalloutNV))
         Or (sSignature = 'LVLI') Or ((sSignature = 'LVLN') And Not wbIsOblivion Or wbIsOblivionR)
         Or ((sSignature = 'LVSP') And (wbIsOblivion Or wbIsOblivionR Or wbIsSkyrim Or wbIsFallout4)))
         And Not TagExists(g_Tag) Then
        // if number of matched entries less than in master list
        If j < ElementCount(kEntriesMaster) Then
          Begin
            AddLogEntry('ElementCount', kEntries, kEntriesMaster);
            slSuggestedTags.Add(g_Tag);
            Exit;
          End;
    End;
End;


Function FriendlyRelationshipWhy(Const ATestName: String): String;
Begin
  If SameText(ATestName, 'Assigned') Then
    Result := 'a subrecord is present on one side of the conflict but missing on the other'
  Else If SameText(ATestName, 'ElementCount') Then
         Result := 'the winning override has a different number of child elements than the master'
  Else If SameText(ATestName, 'ElementCountAdd') Then
         Result := 'the winning override adds child elements relative to the master'
  Else If SameText(ATestName, 'ElementCountRemove') Then
         Result := 'the winning override removes child elements relative to the master'
  Else If SameText(ATestName, 'GetEditValue') Then
         Result := 'the displayed field value differs from the master'
  Else If SameText(ATestName, 'CompareKeys') Then
         Result := 'sorted key contents differ from the master'
  Else If SameText(ATestName, 'SubrecordChange') Then
         Result := 'a list entry the master also has was modified (same reference, different data)'
  Else If SameText(ATestName, 'CompareNativeValues') Then
         Result := 'raw binary/native field values differ from the master'
  Else If SameText(ATestName, 'CompareFlags:NOT') Then
         Result := 'a flag value differs from the master'
  Else If SameText(ATestName, 'CompareFlags:OR') Then
         Result := 'a flag is set on the override or master (OR rule)'
  Else If SameText(ATestName, 'RaceSpells:AddOnly') Then
         Result := 'override Spells adds new SPELs and removes none (additive merge)'
  Else If SameText(ATestName, 'RaceSpells:Removes') Then
         Result := 'override Spells removes SPELs the master had (full override required)'
  Else If SameText(ATestName, 'Heuristic:ForceAddSuperset') Then
         Result := 'heuristic: override list is a strict superset of master (no removals); WB ForceAdd may apply'
  Else If SameText(ATestName, 'Heuristic:FullFaceDiff') Then
         Result := 'heuristic: NPC eyes, hair, and face geometry all differ from master; WB full face import may apply'
  Else
    Result := 'detection rule fired (' + ATestName + ')';
End;


// Collect the EditValue (FormID hex) of each child entry in an array element into sl (sorted, unique).
Procedure CollectArrayEntryIDs(AArray: IwbElement; sl: TStringList);

Var 
  i      : integer;
  kEntry : IwbElement;
  s      : string;
Begin
  If Not Assigned(AArray) Then
    Exit;
  For i := 0 To Pred(ElementCount(AArray)) Do
    Begin
      kEntry := ElementByIndex(AArray, i);
      s := Trim(GetEditValue(kEntry));
      If s <> '' Then
        sl.Add(s);
    End;
End;


// Set diff: items in A not in B
Function CountSetMinus(A: TStringList; B: TStringList): integer;

Var 
  i, n : integer;
Begin
  n := 0;
  For i := 0 To Pred(A.Count) Do
    If B.IndexOf(A[i]) = -1 Then
      Inc(n);
  Result := n;
End;


// Oblivion RACE Spells split (replaces single R.ChangeSpells emission).
//   removes > 0  -> R.ChangeSpells  (full override needed to drop SPELs)
//   adds-only    -> R.AddSpells     (additive merge sufficient)
//   identical    -> nothing
// Preserves v1.0 detection coverage; improves accuracy in the adds-only case.
Procedure ProcessRaceSpells(ARecord: IwbMainRecord; AMaster: IwbMainRecord);

Var 
  kSpells, kSpellsMaster : IwbElement;
  slOver, slMast         : TStringList;
  iAdds, iRemoves        : integer;
Begin
  If TagExists('R.AddSpells') And TagExists('R.ChangeSpells') Then
    Exit;

  // RACE SPLO array name varies by game: TES4 = 'Spells', TES5/SSE/Enderal = 'Actor Effects'.
  If wbIsOblivion Or wbIsOblivionR Then
    Begin
      kSpells       := ElementByPath(ARecord, 'Spells');
      kSpellsMaster := ElementByPath(AMaster,  'Spells');
    End
  Else
    Begin
      kSpells       := ElementByPath(ARecord, 'Actor Effects');
      kSpellsMaster := ElementByPath(AMaster,  'Actor Effects');
    End;

  // Both missing: nothing to suggest. Either-side missing: defer to general path-based check below.
  If Not Assigned(kSpells) And Not Assigned(kSpellsMaster) Then
    Exit;

  slOver := TStringList.Create;
  slMast := TStringList.Create;
  Try
    slOver.Sorted := True;  slOver.Duplicates := dupIgnore;  slOver.CaseSensitive := False;
    slMast.Sorted := True;  slMast.Duplicates := dupIgnore;  slMast.CaseSensitive := False;

    CollectArrayEntryIDs(kSpells,       slOver);
    CollectArrayEntryIDs(kSpellsMaster, slMast);

    iAdds    := CountSetMinus(slOver, slMast);
    iRemoves := CountSetMinus(slMast, slOver);

    If iRemoves > 0 Then
      Begin
        g_Tag := 'R.ChangeSpells';
        If Not TagExists(g_Tag) Then
          Begin
            AddLogEntry('RaceSpells:Removes', kSpells, kSpellsMaster);
            slSuggestedTags.Add(g_Tag);
          End;
      End
    Else If iAdds > 0 Then
           Begin
             g_Tag := 'R.AddSpells';
             If Not TagExists(g_Tag) Then
               Begin
                 AddLogEntry('RaceSpells:AddOnly', kSpells, kSpellsMaster);
                 slSuggestedTags.Add(g_Tag);
               End;
           End;
  Finally
    slOver.Free;
    slMast.Free;
  End;
End;


// Per-entry change diff for sorted/keyed sub-record lists (Items, Relations, etc.).
// Emits ATagName iff at least one entry whose key (ARefPath) is present in BOTH master
// and override has differing data on any of ADataPathsDelim (pipe-separated paths).
//
// Entries that exist only in override (Add) or only in master (Remove) are intentionally
// ignored here — those are handled by *.Add and *.Remove tags. This is the fix for the
// historical false positive where CompareKeys on the whole array would fire whenever
// items were added or removed, regardless of whether any shared entry actually changed.
Procedure DiffSubrecordList(ARec: IInterface; AMaster: IInterface;
                             Const ATagName: String; Const AArrayName: String;
                             Const ARefPath: String; Const ADataPathsDelim: String);

Var 
  kArr, kArrM         : IwbElement;
  kEntry, kMatch      : IwbElement;
  kSubA, kSubB        : IwbElement;
  slDataPaths         : TStringList;
  i, j, k             : integer;
  sRef, sRefM         : string;
  sData, sDataM       : string;
Begin
  DbgLog(DBG_PER_COMPARE, Format('DiffSubrecordList: tag=%s array=%s ref=%s data=%s',
    [ATagName, AArrayName, ARefPath, ADataPathsDelim]));

  If TagExists(ATagName) Then
    Begin
      DbgLog(DBG_PER_COMPARE, '  -> SKIP (tag already suggested earlier)');
      Exit;
    End;

  kArr  := ElementByName(ARec,    AArrayName);
  kArrM := ElementByName(AMaster, AArrayName);
  If Not Assigned(kArr) Or Not Assigned(kArrM) Then
    Begin
      DbgLog(DBG_PER_COMPARE, Format('  -> NO-OP (array "%s" missing on %s)',
        [AArrayName, IfThen(Not Assigned(kArr), 'override', 'master')]));
      Exit;
    End;
  If (ElementCount(kArr) = 0) Or (ElementCount(kArrM) = 0) Then
    Begin
      DbgLog(DBG_PER_COMPARE, Format('  -> NO-OP (one side empty: e=%s m=%s)',
        [IntToStr(ElementCount(kArr)), IntToStr(ElementCount(kArrM))]));
      Exit;
    End;

  slDataPaths := TStringList.Create;
  Try
    slDataPaths.Delimiter     := '|';
    slDataPaths.StrictDelimiter := True;
    slDataPaths.DelimitedText := ADataPathsDelim;

    For i := 0 To Pred(ElementCount(kArr)) Do
      Begin
        kEntry := ElementByIndex(kArr, i);
        sRef   := GetElementEditValues(kEntry, ARefPath);
        If sRef = '' Then
          Begin
            DbgLog(DBG_PER_COMPARE, Format('  entry[%s]: no ref value at "%s" -> skip', [IntToStr(i), ARefPath]));
            Continue;
          End;

        // Find the matching entry in master by ref (linear scan; lists are small).
        kMatch := Nil;
        For j := 0 To Pred(ElementCount(kArrM)) Do
          Begin
            sRefM := GetElementEditValues(ElementByIndex(kArrM, j), ARefPath);
            If SameText(sRefM, sRef) Then
              Begin
                kMatch := ElementByIndex(kArrM, j);
                Break;
              End;
          End;

        // Ref only in override = Add (handled by *.Add tag); skip.
        If Not Assigned(kMatch) Then
          Begin
            DbgLog(DBG_PER_COMPARE, Format('  entry[%s] ref="%s" -> add-only (no master match), skip', [IntToStr(i), sRef]));
            Continue;
          End;

        // Compare each requested data path. First difference wins and emits the tag.
        For k := 0 To Pred(slDataPaths.Count) Do
          Begin
            kSubA := ElementByPath(kEntry, slDataPaths[k]);
            kSubB := ElementByPath(kMatch, slDataPaths[k]);

            // Both missing on this path: nothing to compare.
            If Not Assigned(kSubA) And Not Assigned(kSubB) Then
              Continue;

            sData  := '';
            sDataM := '';
            If Assigned(kSubA) Then sData  := EditValues(kSubA);
            If Assigned(kSubB) Then sDataM := EditValues(kSubB);

            If Not SameText(sData, sDataM) Then
              Begin
                g_Tag := ATagName;
                AddLogEntry('SubrecordChange', kEntry, kMatch);
                slSuggestedTags.Add(g_Tag);
                DbgLog(DBG_PER_COMPARE, Format('  entry[%s] ref="%s" data-path="%s" DIFFERS -> SUGGEST %s',
                  [IntToStr(i), sRef, slDataPaths[k], ATagName]));
                DbgLog(DBG_LEAF_DIFFS, Format('       override="%s"  master="%s"',
                  [DbgShortVal(sData), DbgShortVal(sDataM)]));
                Exit;
              End;
          End;
      End;
    DbgLog(DBG_PER_COMPARE, '  -> NO-OP (all shared entries had identical data on requested paths)');
  Finally
    slDataPaths.Free;
  End;
End;


// Opt-in heuristic: suggest WB Force* variants when simple diff patterns fire.
// Documented false positives; gated by g_HeuristicForceTags.
Procedure ProcessForceTagHeuristics(ARecord: IwbMainRecord; AMaster: IwbMainRecord);

Var 
  sSig                       : string;
  kArr, kArrMaster           : IwbElement;
  slOver, slMast             : TStringList;
  iAdds, iRemoves            : integer;
  bSpells, bAI               : boolean;
  bEyes, bHair, bFace        : boolean;
  kE, kEM, kH, kHM, kF, kFM  : IwbElement;
Begin
  If Not g_HeuristicForceTags Then
    Exit;

  sSig := Signature(ARecord);

  // Actors.SpellsForceAdd: superset on the SPLO array, only if Actors.Spells already suggested.
  // Array element name: TES4 = 'Spells', everything else = 'Actor Effects'.
  bSpells := (sSig = 'CREA') Or (sSig = 'NPC_');
  If bSpells And TagExists('Actors.Spells') And Not TagExists('Actors.SpellsForceAdd') Then
    Begin
      If wbIsOblivion Or wbIsOblivionR Then
        Begin
          kArr       := ElementByPath(ARecord, 'Spells');
          kArrMaster := ElementByPath(AMaster,  'Spells');
        End
      Else
        Begin
          kArr       := ElementByPath(ARecord, 'Actor Effects');
          kArrMaster := ElementByPath(AMaster,  'Actor Effects');
        End;

      slOver := TStringList.Create;
      slMast := TStringList.Create;
      Try
        slOver.Sorted := True;  slOver.Duplicates := dupIgnore;  slOver.CaseSensitive := False;
        slMast.Sorted := True;  slMast.Duplicates := dupIgnore;  slMast.CaseSensitive := False;
        CollectArrayEntryIDs(kArr,       slOver);
        CollectArrayEntryIDs(kArrMaster, slMast);
        iAdds    := CountSetMinus(slOver, slMast);
        iRemoves := CountSetMinus(slMast, slOver);
        If (iAdds > 0) And (iRemoves = 0) Then
          Begin
            g_Tag := 'Actors.SpellsForceAdd';
            AddLogEntry('Heuristic:ForceAddSuperset', kArr, kArrMaster);
            slSuggestedTags.Add(g_Tag);
          End;
      Finally
        slOver.Free;
        slMast.Free;
      End;
    End;

  // Actors.AIPackagesForceAdd: superset on Packages, only if Actors.AIPackages already suggested.
  bAI := (sSig = 'CREA') Or (sSig = 'NPC_');
  If bAI And TagExists('Actors.AIPackages') And Not TagExists('Actors.AIPackagesForceAdd') Then
    Begin
      kArr       := ElementByPath(ARecord, 'Packages');
      kArrMaster := ElementByPath(AMaster,  'Packages');

      slOver := TStringList.Create;
      slMast := TStringList.Create;
      Try
        slOver.Sorted := True;  slOver.Duplicates := dupIgnore;  slOver.CaseSensitive := False;
        slMast.Sorted := True;  slMast.Duplicates := dupIgnore;  slMast.CaseSensitive := False;
        CollectArrayEntryIDs(kArr,       slOver);
        CollectArrayEntryIDs(kArrMaster, slMast);
        iAdds    := CountSetMinus(slOver, slMast);
        iRemoves := CountSetMinus(slMast, slOver);
        If (iAdds > 0) And (iRemoves = 0) Then
          Begin
            g_Tag := 'Actors.AIPackagesForceAdd';
            AddLogEntry('Heuristic:ForceAddSuperset', kArr, kArrMaster);
            slSuggestedTags.Add(g_Tag);
          End;
      Finally
        slOver.Free;
        slMast.Free;
      End;
    End;

  // NpcFacesForceFullImport: NPC_ on non-FO4, all of eyes (ENAM), hair (HNAM),
  // and face geometry (FaceGen Data) differ from master simultaneously.
  If (sSig = 'NPC_') And Not wbIsFallout4 And Not TagExists('NpcFacesForceFullImport') Then
    Begin
      kE  := ElementBySignature(ARecord, 'ENAM');
      kEM := ElementBySignature(AMaster, 'ENAM');
      kH  := ElementBySignature(ARecord, 'HNAM');
      kHM := ElementBySignature(AMaster, 'HNAM');
      kF  := ElementByPath(ARecord, 'FaceGen Data');
      kFM := ElementByPath(AMaster,  'FaceGen Data');

      bEyes := Assigned(kE) And Assigned(kEM) And (GetNativeValue(kE) <> GetNativeValue(kEM));
      bHair := Assigned(kH) And Assigned(kHM) And (GetNativeValue(kH) <> GetNativeValue(kHM));
      bFace := Assigned(kF) And Assigned(kFM) And Not SameText(EditValues(kF), EditValues(kFM));

      If bEyes And bHair And bFace Then
        Begin
          g_Tag := 'NpcFacesForceFullImport';
          AddLogEntry('Heuristic:FullFaceDiff', kF, kFM);
          slSuggestedTags.Add(g_Tag);
        End;
    End;
End;


Function AddLogEntry(ATestName: String; AElement: IwbElement; AMaster: IwbElement): string;

Var 
  mr    : IwbMainRecord;
  sName : string;
  sPath : string;
  sWhy  : string;
Begin
  If Not g_LogTests And Not g_ShowTagRelationships Then
    Exit;

  If Assigned(AMaster) Then
    Begin
      mr    := ContainingMainRecord(AMaster);
      sPath := Path(AMaster);
    End
  Else
    Begin
      mr    := ContainingMainRecord(AElement);
      sPath := Path(AElement);
    End;

  sPath := RightStr(sPath, Length(sPath) - 5);

  sName := Format('[%s:%s]', [Signature(mr), IntToHex(GetLoadOrderFormID(mr), 8)]);

  If g_LogTests Then
    slLog.Add(Format('{%s} (%s) %s %s', [g_Tag, ATestName, sName, sPath]));

  If g_ShowTagRelationships Then
    Begin
      sWhy := FriendlyRelationshipWhy(ATestName);
      slTagRelationships.Add(Format('Tag suggestion %s based on %s at %s %s', [g_Tag, sWhy, sName, sPath]));
    End;
End;


Function FileByName(AFileName: String): IwbFile;

Var 
  kFile : IwbFile;
  i     : integer;
Begin
  Result := Nil;

  For i := 0 To Pred(FileCount) Do
    Begin
      kFile := FileByIndex(i);
      If SameText(AFileName, GetFileName(kFile)) Then
        Begin
          Result := kFile;
          Exit;
        End;
    End;
End;


Procedure EscKeyHandler(Sender: TObject; Var Key: Word; Shift: TShiftState);
Begin
  If Key = 27 Then
    Sender.Close;
End;


Procedure chkAddTagsClick(Sender: TObject);
Begin
  // READ-ONLY DEBUG FORK: g_AddTags is unconditionally False; ignore checkbox state.
  g_AddTags := False;
End;

Procedure chkAddFileClick(Sender: TObject);
Begin
  g_AddFile := Sender.Checked;
End;


Procedure chkLoggingClick(Sender: TObject);
Begin
  g_LogTests := Sender.Checked;
End;


Procedure chkTagRelationshipsClick(Sender: TObject);
Begin
  g_ShowTagRelationships := Sender.Checked;
End;


Procedure chkHeuristicForceTagsClick(Sender: TObject);
Begin
  g_HeuristicForceTags := Sender.Checked;
End;


Function ShowPrompt(ACaption: String): integer;

Var 
  frm                : TForm;
  chkAddTags         : TCheckBox;
  chkAddFile         : TCheckBox;
  chkLogging         : TCheckBox;
  chkTagRelations    : TCheckBox;
  chkHeuristicForce  : TCheckBox;
  btnCancel          : TButton;
  btnOk              : TButton;
  i                  : integer;
Begin
  Result := mrCancel;

  frm := TForm.Create(TForm(frmMain));

  Try
    frm.Caption      := ACaption;
    frm.BorderStyle  := bsToolWindow;
    frm.ClientWidth  := 360 * ScaleFactor;
    frm.ClientHeight := 211 * ScaleFactor;
    frm.Position     := poScreenCenter;
    frm.KeyPreview   := True;
    frm.OnKeyDown    := EscKeyHandler;

    chkAddTags := TCheckBox.Create(frm);
    chkAddTags.Parent   := frm;
    chkAddTags.Left     := 16 * ScaleFactor;
    chkAddTags.Top      := 16 * ScaleFactor;
    chkAddTags.Width    := 280 * ScaleFactor;
    chkAddTags.Height   := 16 * ScaleFactor;
    chkAddTags.Caption  := 'Write suggested tags to header (DISABLED in debug fork)';
    chkAddTags.Checked  := False;
    chkAddTags.Enabled  := False;     // READ-ONLY DEBUG FORK
    g_AddTags := False;               // never honored regardless of checkbox state
    chkAddTags.OnClick  := chkAddTagsClick;
    chkAddTags.TabOrder := 0;

    chkAddFile := TCheckBox.Create(frm);
    chkAddFile.Parent   := frm;
    chkAddFile.Left     := 16 * ScaleFactor;
    chkAddFile.Top      := 39 * ScaleFactor;
    chkAddFile.Width    := 280 * ScaleFactor;
    chkAddFile.Height   := 16 * ScaleFactor;
    chkAddFile.Caption  := 'Write suggested tags to file (DISABLED in debug fork)';
    chkAddFile.Checked  := False;
    chkAddFile.Enabled  := False;     // READ-ONLY DEBUG FORK
    g_AddFile := False;               // never honored regardless of checkbox state
    chkAddFile.OnClick  := chkAddFileClick;
    chkAddFile.TabOrder := 0;

    chkLogging := TCheckBox.Create(frm);
    chkLogging.Parent   := frm;
    chkLogging.Left     := 16 * ScaleFactor;
    chkLogging.Top      := 62 * ScaleFactor;
    chkLogging.Width    := 185 * ScaleFactor;
    chkLogging.Height   := 16 * ScaleFactor;
    chkLogging.Caption  := 'Log test results to Messages tab';
    chkLogging.Checked  := True;
    g_LogTests := chkLogging.Checked;
    chkLogging.OnClick  := chkLoggingClick;
    chkLogging.TabOrder := 1;

    chkTagRelations := TCheckBox.Create(frm);
    chkTagRelations.Parent   := frm;
    chkTagRelations.Left     := 16 * ScaleFactor;
    chkTagRelations.Top      := 85 * ScaleFactor;
    chkTagRelations.Width    := 210 * ScaleFactor;
    chkTagRelations.Height   := 16 * ScaleFactor;
    chkTagRelations.Caption  := 'Show Tag to Record Relationships';
    chkTagRelations.Checked  := True;
    g_ShowTagRelationships := chkTagRelations.Checked;
    chkTagRelations.OnClick  := chkTagRelationshipsClick;
    chkTagRelations.TabOrder := 2;

    chkHeuristicForce := TCheckBox.Create(frm);
    chkHeuristicForce.Parent   := frm;
    chkHeuristicForce.Left     := 16 * ScaleFactor;
    chkHeuristicForce.Top      := 108 * ScaleFactor;
    chkHeuristicForce.Width    := 336 * ScaleFactor;
    chkHeuristicForce.Height   := 16 * ScaleFactor;
    chkHeuristicForce.Caption  := 'Suggest heuristic Force* tags (may produce false positives)';
    chkHeuristicForce.Checked  := False;
    g_HeuristicForceTags := chkHeuristicForce.Checked;
    chkHeuristicForce.OnClick  := chkHeuristicForceTagsClick;
    chkHeuristicForce.TabOrder := 3;

    btnOk := TButton.Create(frm);
    btnOk.Parent              := frm;
    btnOk.Left                := 102 * ScaleFactor;
    btnOk.Top                 := 173 * ScaleFactor;
    btnOk.Width               := 75 * ScaleFactor;
    btnOk.Height              := 25 * ScaleFactor;
    btnOk.Caption             := 'Run';
    btnOk.Default             := True;
    btnOk.ModalResult         := mrOk;
    btnOk.TabOrder            := 3;

    btnCancel := TButton.Create(frm);
    btnCancel.Parent          := frm;
    btnCancel.Left            := 183 * ScaleFactor;
    btnCancel.Top             := 173 * ScaleFactor;
    btnCancel.Width           := 75 * ScaleFactor;
    btnCancel.Height          := 25 * ScaleFactor;
    btnCancel.Caption         := 'Abort';
    btnCancel.ModalResult     := mrAbort;
    btnCancel.TabOrder        := 4;

    Result := frm.ShowModal;
  Finally
    frm.Free;
  End;
End;

End.
