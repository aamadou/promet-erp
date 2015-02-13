unit usimapmailbox;

interface

uses Classes, usimapsearch;

type
  TMessageSet = array of Integer;
  TStoreMode  = set of ( smAdd, smReplace, smDelete );

  tOnNewMess = procedure of Object; //HSR //IDLE
  tOnExpunge = procedure (Number : Integer) of Object; //HSR //IDLE

  pIMAPNotification = ^tIMAPNotification;
  tIMAPNotification = record //HSR //IDLE
    OnNewMess : tOnNewMess;
    OnExpunge : tOnExpunge;
  end;

  TImapMailbox = class
    private
      fCritSection : TRTLCriticalSection;
      fIndex       : TImapMailboxIndex;
      fPath        : String;
      fStatus      : TMbxStatus;
      fUsers       : TList;
      fReadOnly    : Boolean; //ClientRO
      function  GetStatus: TMbxStatus;
      procedure AddMessage( Flags: String; TimeStamp: TUnixTime );
      function  StringToFlagMask( Flags: String ): TFlagMask;
      function  FlagMaskToString( FlagMask: TFlagMask ): String;
      function  GetPossFlags: String;
      procedure WriteStatus; //Not Critical_Section-Protected!
      {MG}{Search-new}
      function  Find( Search: TIMAPSearch; MsgSet: TMessageSet ): TMessageSet;
      function  JoinMessageSets( MsgSet1, MsgSet2: TMessageSet ): TMessageSet;
      function  FindMessageSets( MsgSet1, MsgSet2: TMessageSet; Exclude: Boolean ): TMessageSet;
      function  FindFlags( MsgSet: TMessageSet; Flags: TFlagMask; Exclude: Boolean ): TMessageSet;
      function  FindSize( MsgSet: TMessageSet; Min, Max: Integer ): TMessageSet;
      function  FindTimeStamp( MsgSet: TMessageSet; After, Before: Int64 ): TMessageSet;
      function  FindContent( MsgSet: TMessageSet; After, Before: Int64; Charset: String;
                             HeaderList, BodyStrings, TextStrings: TStringList): TMessageSet;
      {/Search-new}
    public
      function  RebuildStatusFile: TMbxStatus;
      function  StrToMsgSet( s: String; UseUID: Boolean ): TMessageSet;

      property  Status         : TMBxStatus read  fStatus;
      property  Path           : String     read  fPath;
      property  MBReadOnly     : Boolean    read  fReadOnly write fReadOnly; //ClientRO //ToDo: 'write' von ReadOnly löschen oder umfunktionieren 
      property  GetUIDnext     : LongInt    read  fStatus.UIDNext;
      property  GetUIDvalidity : TUnixTime  read  fStatus.UIDvalidity;
      property  PossFlags      : String     read  GetPossFlags;
      procedure Lock;
      procedure Unlock;
      procedure RemoveRecentFlags;
      procedure AddUser( Notify : pIMAPNotification );
      procedure RemoveUser( Notify : pIMAPNotification; out NoUsersLeft: Boolean );
      procedure Expunge( ExcludeFromResponse: pIMAPNotification );

      function  Search( SearchStruct: TIMAPSearch; UseUID: Boolean ): String; {MG}{Search-new}
      function  Fetch( Idx: Integer; MsgDat: String; var Success: Boolean ): String;
      function  CopyMessage( MsgSet: TMessageSet; Destination: TImapMailbox ): Boolean;
      function  Store( Idx: Integer; Flags: String; Mode: TStoreMode ): String;
      function  AppendMessage( MsgTxt: String; Flags: String; TimeStamp: TUnixTime ): String;
      function  AreValidFlags(Flags: String) : Boolean;

      procedure AddIncomingMessage(Const Flags : String = '');
      procedure SendMailboxUpdate;

      constructor Create( APath: String );
      destructor Destroy; override;
  end;

//------------------------------------------------------------------------------
implementation

uses uTools, Sysutils, cLogFile, cAccount, uIMAPUtils, cIMAPMessage,
     Config, uEncoding, FileCtrl, cArticle, Global;

// --------------------------------------------------------- TImapMailbox -----
function TImapMailbox.StringToFlagMask( Flags: String ): TFlagMask;
begin
     Result := FLAGNONE;
     Flags := uppercase(Flags);
     if pos( '\SEEN',     Flags ) > 0 then Result := Result or FLAGSEEN;
     if pos( '\ANSWERED', Flags ) > 0 then Result := Result or FLAGANSWERED;
     if pos( '\FLAGGED',  Flags ) > 0 then Result := Result or FLAGFLAGGED;
     if pos( '\DELETED',  Flags ) > 0 then Result := Result or FLAGDELETED;
     if pos( '\DRAFT',    Flags ) > 0 then Result := Result or FLAGDRAFT;
     if pos( '\RECENT',   Flags ) > 0 then Result := Result or FLAGRECENT;
     //Moder
     if pos( '\APPROVE',  Flags ) > 0 then Result := Result or FLAGAPPROVE;
     if pos( '\DECLINE',  Flags ) > 0 then Result := Result or FLAGDECLINE;
end;

function TImapMailbox.FlagMaskToString( FlagMask: TFlagMask ): String;
begin
     Result := '';

     //Moder
     if FlagMask and FLAGAPPROVE  = FLAGAPPROVE  then Result := Result + ' \Approve';
     if FlagMask and FLAGDECLINE  = FLAGDECLINE  then Result := Result + ' \Decline';


     if FlagMask and FLAGSEEN     = FLAGSEEN     then Result := Result + ' \Seen';
     if FlagMask and FLAGANSWERED = FLAGANSWERED then Result := Result + ' \Answered';
     if FlagMask and FLAGFLAGGED  = FLAGFLAGGED  then Result := Result + ' \Flagged';
     if FlagMask and FLAGDELETED  = FLAGDELETED  then Result := Result + ' \Deleted';
     if FlagMask and FLAGDRAFT    = FLAGDRAFT    then Result := Result + ' \Draft';
     if FlagMask and FLAGRECENT   = FLAGRECENT   then Result := Result + ' \Recent';
     if Result<>'' then Delete( Result, 1, 1 );
     Result := '(' + Result + ')';
end;

function  TImapMailbox.AreValidFlags(Flags: String) : Boolean;
begin
  Result := not (pos('\RECENT', Flags)>0)
end;

function TImapMailbox.GetPossFlags: String;
begin
  Result := '(\Answered \Flagged \Deleted \Seen \Draft)'
end;

function TImapMailbox.GetStatus: TMbxStatus;
var  RebuildNeeded : Boolean;
begin
     RebuildNeeded := False;
     FillChar( Result, SizeOf(Result), 0 );
     if FileExists2( fPath + IMAPSTATUS_FILENAME ) then begin
        with TFileStream.Create( fPath + IMAPSTATUS_FILENAME, fmOpenRead ) do try
           if Read( Result, SizeOf(Result) ) <> SizeOf(Result) then begin
              Log( LOGID_WARN, 'IMAPMailbox.readingStatusFile.failed', 'Error reading imap mailbox status file.' );
              RebuildNeeded := True;
           end
        finally Free end
     end else RebuildNeeded := True;
     if RebuildNeeded then Result := RebuildStatusFile;
end;

function TImapMailbox.RebuildStatusFile: TMbxStatus;
var  Status     : TMbxStatus;
     MR         : TMessageRec;
     Chunk      : Byte;
     i          : Integer;
begin
     Log( LOGID_INFO, 'IMAPMailbox.rebuildingStatusFile', 'Rebuilding mailbox status file.' );

     FillChar( Status, SizeOf(Status), 0 );
     Status.UIDvalidity := DateTimeToUnixTime( NowGMT );
     Status.UIDnext     := 1;

     FillChar( MR, sizeof(MR), 0 );
     Chunk := fIndex.pubChunkOf( MR );
     try
       Lock;
       fIndex.Enter( Chunk );
       try
          Status.Messages := fIndex.Count;
          for i := 0 to Status.Messages-1 do begin
             fIndex.pubRecGet( Chunk, i, MR );
             if MR.Flags and FLAGSEEN <> FLAGSEEN then inc( Status.Unseen );
             if MR.Flags and FLAGRECENT = FLAGRECENT then inc( Status.Recent );
             // if MR.UID >= Status.UIDnext then Status.UIDnext := MR.UID + 1;
          end;
          {MG}{IMAP-UID-ByteOrder}
          fIndex.pubRecGet( Chunk, Status.Messages-1, MR );
          if SwitchByteOrder( MR.UID ) >= Status.UIDnext then begin
             Status.UIDnext := SwitchByteOrder( MR.UID ) + 1
          end;
          {/IMAP-UID-ByteOrder}
       finally
          fIndex.Leave( Chunk );
       end;
     finally
       Unlock;
     end;

     Result := Status;
end;

procedure TImapMailbox.WriteStatus;
begin
   with TFileStream.Create( fPath + IMAPSTATUS_FILENAME, fmCreate ) do try
      if Write( fStatus, SizeOf(fStatus) ) <> SizeOf(fStatus) then
         Log( LOGID_ERROR, 'IMAPMailbox.WritingToDisk.Failed', 'Error writing imap mailbox status to disk.' );
   finally
      Free;
   end;
end;

procedure TImapMailbox.Expunge( ExcludeFromResponse: pIMAPNotification );
var  Chunk : Byte;
     i,j   : Integer;
     MR    : TMessageRec;
     ServerThread : pIMAPNotification;
     FN: String;
begin
   if fReadOnly then exit;
   try
     Lock;
      for Chunk:=0 to fIndex.propCHUNK_MAX do begin
         fIndex.Enter( Chunk );
         try
            for i := fIndex.Count-1 downto 0 do begin
               fIndex.pubRecGet( Chunk, i, MR );
               if (MR.Flags and FLAGDELETED) = FLAGDELETED then begin
                  FN := fPath + IntToStr(SwitchByteOrder(MR.UID)) + '.'+Def_Extension_Mail;
                  If SysUtils.DeleteFile( FN ) then begin
                     if fIndex.ContainsKey(MR, INDEXKEYLEN_UID ) then begin
                       dec( fStatus.Messages );
                       if (MR.Flags and FLAGSEEN) <> FLAGSEEN then dec( fStatus.Unseen );
                       if (MR.Flags and FLAGRECENT) = FLAGRECENT then dec( fStatus.Recent );
                     end;

                     fIndex.RemoveKey( MR, INDEXKEYLEN_UID );
                     for j := 0 to fUsers.Count-1 do begin
                        try
                           if Assigned( fUsers.Items[j] ) then begin
                              ServerThread := pIMAPNotification( fUsers.Items[j] );
                              if ServerThread <> ExcludeFromResponse then begin
                                 ServerThread^.OnExpunge( i+1 )
                              end
                           end
                        except
                        end
                     end
                  end else begin
                     if FileExists2( FN ) then
                       Log( LOGID_ERROR, 'IMAPMailbox.DeletingMessageFile.failed', 
                          'Error deleting imap message file %s in use?', FN )
                     else begin
                       Log( LOGID_WARN, 'IMAPMailbox.DeletingMessageFile.DoesntExist',
                           'Error deleting imap message file %s: Deleted outside', FN );
                       fIndex.RemoveKey( MR, INDEXKEYLEN_UID )
                     end
                  end
               end
            end
         finally
            fIndex.Leave(Chunk)
         end
      end;
      fIndex.SaveToFile;
      WriteStatus
   finally
      Unlock
   end
end;

function TImapMailbox.Store( Idx: Integer; Flags: String; Mode: TStoreMode ): String;
var
  FlagMsk : tFlagMask;
begin
  if fReadOnly then begin
    Result := FlagMaskToString(fIndex.GetFlags( Idx ));
    exit
  end;
  try
     Lock;
     FlagMsk := StringToFlagMask(Flags);
     if FlagMsk and FLAGSEEN = FLAGSEEN then begin
        if fIndex.GetFlags(Idx) and FLAGSEEN = FLAGSEEN then begin
           if Mode = [smDelete] then inc( fStatus.Unseen )
        end else begin
           if Mode <= [smReplace, smAdd] then dec( fStatus.Unseen )
        end
     end else begin
        if (fIndex.GetFlags(Idx) and FLAGSEEN = FLAGSEEN) then
           if Mode = [smReplace] then inc( fStatus.Unseen );
     end;

     if      Mode = [smReplace] then FlagMsk := fIndex.SetFlags   ( Idx, FlagMsk )
     else if Mode = [smDelete]  then FlagMsk := fIndex.RemoveFlags( Idx, FlagMsk )
     else if Mode = [smAdd]     then FlagMsk := fIndex.AddFlags   ( Idx, FlagMsk )
     else                            FlagMsk := fIndex.GetFlags   ( Idx ); // just in case ...
     Result := FlagMaskToString(FlagMsk);
     WriteStatus
  finally
     Unlock;
  end;
end;

procedure TImapMailbox.RemoveRecentFlags;
var  i: Integer;
begin
  lock;
  try
    if fReadOnly then exit;
    for i := 0 to fIndex.Count-1 do fIndex.RemoveFlags( i, FLAGRECENT );
    fStatus.Recent := 0;
  finally
    unlock
  end
end;

procedure TImapMailbox.AddMessage( Flags: String; TimeStamp: TUnixTime );
var FMFlags : tFlagMask;
begin
  try
     Lock;
     FMFlags := StringToFlagMask(Flags);
     fIndex.AddEntry( GetUIDnext, FMFlags, TimeStamp );
     inc( fStatus.UIDnext );
     inc( fStatus.Messages );
     if FMFlags and FLAGSEEN <> FLAGSEEN then inc( fStatus.Unseen );
     if FMFlags and FLAGRECENT = FLAGRECENT then inc( fStatus.Recent );
  finally
     Unlock;
  end;
end;

{AP2} {Destination-Lock fuer MessageCopy}
function TImapMailbox.CopyMessage( MsgSet: TMessageSet; Destination:TImapMailbox ): Boolean;
var  i: Integer;
     FileNameS,FileNameD: String;
     listFileNameD: TStringList;
     pMessageRec: TPMessageRec;
     nUIDnext: LongInt;
begin
  if Destination.MBReadOnly then begin
    Result := false;
    exit
  end;
  listFileNameD := TStringList.Create;
  listFileNameD.Sorted:=False;
  Result := True;
  try
    Lock;
    try
      for i := 0 to High(MsgSet) do begin
        FileNameS := fPath + fIndex.GetUIDStr(MsgSet[i]-1) + '.'+Def_Extension_Mail;
        if not FileExists2( FilenameS ) then begin Result := False;Break; end;
        SetLength(FileNameD, MAX_PATH);
        if 0=GetTempFileName(PChar(Destination.Path), '~CM', 0,PChar(FileNameD)) then
          begin Result := False; Break; end;
        SetLength(FileNameD, Pos(#0, FileNameD)-1);
        if Windows.CopyFile( PChar(FilenameS), PChar(FileNameD), False )then
        begin
          LogRaw( LOGID_DEBUG, 'Message file '+FileNameS+' copied to '+FileNameD );
          new(pMessageRec);
          pMessageRec^.TimeStamp := fIndex.GetTimeStamp(MsgSet[i]-1);
          pMessageRec^.Flags  := fIndex.GetFlags(MsgSet[i]-1) or FLAGRECENT;
          listFileNameD.AddObject(FileNameD,tObject(pMessageRec));
        end else begin
          Log( LOGID_WARN, 'IMAPMailbox.CopyMessage.failed', 
             'Error copying message %s to %s', [FileNameS, FileNameD] );
          Result := False;
          Break;
        end;
      end;
    finally
      Unlock;
    end;

    Destination.Lock;
    try
      nUIDnext := Destination.GetUIDnext;
      i:=0;
      with listFileNameD do while i<Count do begin
        FileNameD := Destination.Path + IntToStr(nUIDnext) + '.'+Def_Extension_Mail;
        if Windows.MoveFile( PChar(Strings[i]), PChar( FileNameD ) ) then
        begin
          LogRaw( LOGID_DEBUG, 'Message file '+Strings[i]+ ' renamed to '+FileNameD );
          Strings[i]:= FileNameD;
          inc(nUIDnext);
        end else begin
          Log( LOGID_WARN, 'IMAPMailbox.Rename.failed', 'Error renaming message %s to %s', 
             [Strings[i], FileNameD] );
          Result := False;
          Break;
        end;
        inc(i);
      end; // with listFileNameD do while
      if Result then with listFileNameD do while 0<Count do begin
        Destination.AddMessage(FlagMaskToString(TPMessageRec(Objects[0]).Flags),
                    TPMessageRec(Objects[0]).TimeStamp);
        with TFileStream.Create( Strings[0], fmOpenRead ) do try
           FileSetDate(handle, DateTimeToFileDate(UnixTimeToDateTime(TPMessageRec(Objects[0]).TimeStamp)));
        finally free end;
        dispose(TPMessageRec(Objects[0]));
        Delete(0);
      end; // with listFileNameD do while

    finally
      Destination.Unlock;
    end;
  finally
    with listFileNameD do while Count>0 do
    begin
      dispose(TPMessageRec(Objects[0]));
      DeleteFile(Strings[0]);
      Delete(0);
    end;
    listFileNameD.Free
  end;

  Destination.SendMailboxUpdate;
end;
{/Destination-Lock fuer MessageCopy}

function TImapMailbox.AppendMessage( MsgTxt: String; Flags: String;
                                     TimeStamp: TUnixTime ): String;
var  Bytes    : Integer;
     FileName : String;
begin
  Result   := 'NO APPEND error: [Read-Only] ';
  if fReadOnly then exit; //ClientRO

  Result   := 'NO APPEND error';

  FileName := fPath + IntToStr( GetUIDnext ) + '.'+Def_Extension_Mail;
  try
     Lock;
     try
        with TFileStream.Create( FileName, fmCreate ) do try
           If MsgTxt > ''
              then Bytes := Write( MsgTxt[1], Length(MsgTxt) )
              else Bytes := 0;
           //AP: IMAPDateSet
           FileSetDate(Handle,DateTimeToFileDate(UnixTimeToDateTime(Timestamp)));
        finally Free end;
        if Bytes = Length(MsgTxt) then begin
           AddMessage( Flags, TimeStamp );
           LogRaw( LOGID_DETAIL, 'Message appended to imap mailbox "' + fPath + '" with Flags: ' + Flags);
           Result := 'OK APPEND completed';
           SendMailboxUpdate;
        end else begin
           Log( LOGID_ERROR, 'IMAPMailbox.AppendingMessage.failed', 
              'Error appending message to imap mailbox "%s"', fPath);
        end;
     except
        on E: Exception do
           Log( LOGID_ERROR, 'IMAPMailbox.AppendingMessage.error', 
              'Couldn''t append message: %s', E.Message );
     end;
  finally
     Unlock;
  end;
end;

procedure TImapMailbox.AddIncomingMessage(Const Flags : String = '');
begin
   if Flags = ''
      then AddMessage( FlagMaskToString(FLAGRECENT), DateTimeToUnixTime(NowGMT) )
      else AddMessage( Flags, DateTimeToUnixTime(NowGMT) );
   SendMailboxUpdate;
end;

procedure TImapMailbox.SendMailboxUpdate;
var  i: Integer;
begin
  for i := 0 to fUsers.Count-1 do try
    if Assigned( fUsers.Items[i] ) then begin
      pIMAPNotification(fUsers.Items[i])^.OnNewMess;
{
           TSrvIMAPCli( Users.Items[i] ).SendRes( IntToStr(GetMessages) + ' EXISTS');
           if FirstUser then begin
              TSrvIMAPCli( Users.Items[i] ).SendRes( IntToStr(GetRecent) + ' RECENT');
              RemoveRecentFlags;
              FirstUser := False;
           end }
    end
  except Continue end;
  if not fReadOnly then
    RemoveRecentFlags;
end;

function ExtractParameter(var Params: String): String;
var  i: Integer;
begin
     Params := TrimWhSpace( Params );
     i := PosWhSpace( Params );
     if (i > 0) and (Pos( '[', Params ) < i) and (Pos( ']', Params ) > i) then begin
        i := Pos( ']', Params ) + 1;
        while i <= Length( Params ) do begin
           if Params[i] in [#9,' '] then break;
           inc( i )
        end
     end;
     if (i > 0) then begin
        Result := Uppercase( TrimQuotes( copy( Params, 1, i-1 ) ) );
        Params := TrimWhSpace( copy( Params, i+1, length(Params)-i ) );
     end else begin
        Result := Uppercase( TrimQuotes( Params ) );
        Params := '';
     end
end;

function TImapMailbox.Fetch( Idx: Integer; MsgDat: String; var Success: Boolean ): String;

  function MakeLiteral( Txt: String ): String;
  begin
     Result := '{' + IntToStr( Length(Txt) ) + '}' + #13#10 + Txt
  end;

var  Filename, Args, DataItem, Data: String;
     MyMail: TImapMessage;

  procedure AddDataValue( NewValue: String );
  begin 
     Data := Data + ' ' + DataItem + ' ' + NewValue
  end;

begin
   Args    := MsgDat;
   Data    := '';
   MyMail := nil;
   Filename := fPath + fIndex.GetUIDStr( Idx ) + '.'+Def_Extension_Mail;
   if not FileExists2( Filename ) then exit;
   try
      repeat
         DataItem := ExtractParameter( Args );
         if DataItem = 'FLAGS' then begin
            AddDataValue( FlagMaskToString( fIndex.GetFlags(Idx) ) )
         end else 
         if DataItem = 'INTERNALDATE' then begin
            AddDataValue( '"' + DateTimeGMTToImapDateTime( UnixTimeToDateTime(
                          fIndex.GetTimeStamp(Idx) ), '+0000' ) + '"' )
         end else 
         if DataItem = 'UID' then begin
            AddDataValue( fIndex.GetUIDStr(Idx) )
         end else begin
            If Not Assigned(MyMail) then begin
               MyMail := TImapMessage.Create;
               MyMail.LoadFromFile( Filename )
            end;
            if DataItem = 'ENVELOPE' then AddDataValue( MyMail.Envelope )
            else if DataItem = 'RFC822' then AddDataValue( MakeLiteral( MyMail.Text ) )
            else if DataItem = 'RFC822.HEADER' then AddDataValue( MakeLiteral( MyMail.FullHeader + #13#10 ) )
            else if DataItem = 'RFC822.TEXT' then AddDataValue( MakeLiteral( MyMail.FullBody ) )
            else if DataItem = 'RFC822.SIZE' then AddDataValue( IntToStr( Length(MyMail.Text) ) )
            else if DataItem = 'BODYSTRUCTURE' then AddDataValue( MyMail.BodyStructure( True ) )
            else if DataItem = 'BODY' then AddDataValue( MyMail.BodyStructure( False ) )
            else if Copy( DataItem, 1, 4 ) = 'BODY' then begin
               if Copy( DataItem, 5, 5 ) = '.PEEK' then System.Delete( DataItem, 5, 5 )
               else if fIndex.GetFlags( Idx ) and FLAGSEEN <> FLAGSEEN then begin
                  // The \Seen flag is implicitly set; if this causes the flags to
                  // change they SHOULD be included as part of the FETCH responses.
                  Store(idx, '\seen', [smAdd]);
                  Args := Args + ' FLAGS';
               end;
               AddDataValue( MakeLiteral( MyMail.BodySection( DataItem ) ) )
            end else begin
               Log( LOGID_WARN, 'IMAPMailbox.Fetch.UnsupportedPar', 
                  'Unsupported Imap FETCH parameter: "%s"', DataItem);
               Success := False
            end
         end;
      until Args = '';
   finally 
      FreeAndNil(MyMail) 
   end;
   System.Delete( Data, 1, 1 );
   Result := IntToStr(Idx+1) + ' FETCH (' + Data + ')'
end;

procedure TImapMailbox.AddUser( Notify : pIMAPNotification );
begin
     LogRaw( LOGID_DEBUG, 'TImapMailbox.AddUser (current user count: '
                  + IntToStr(fUsers.Count) +')' ); {MG}{ImapLog}
     fUsers.Add( Notify );
end;

procedure TImapMailbox.RemoveUser( Notify : pIMAPNotification; out NoUsersLeft: Boolean );
var  i : Integer;
begin
     LogRaw( LOGID_DEBUG, 'TImapMailbox.RemoveUser (current user count: '
                   + IntToStr(fUsers.Count) +')' ); {MG}{ImapLog}
     NoUsersLeft := False;
     i := fUsers.IndexOf( Notify );
     if i >= 0 then fUsers.Delete( i );
     if fUsers.Count = 0 then NoUsersLeft := True;
end;

procedure TImapMailbox.Lock;
begin
     EnterCriticalSection( fCritSection );
end;

procedure TImapMailbox.Unlock;
begin
     LeaveCriticalSection( fCritSection );
end;

constructor TImapMailbox.Create( APath: String );
begin
   inherited Create;
   LogRaw( LOGID_DEBUG, 'TImapMailbox.Create ' + APath ); {MG}{ImapLog}
   InitializeCriticalSection( fCritSection );
   fPath   := APath;
   ForceDirectories(APath); 
   fUsers  := TList.Create;
   fIndex  := TImapMailboxIndex.Create( fPath );
   fStatus := GetStatus;
   fReadOnly := false; //ClientRO
   //ToDo: Read-Only einzelner Mailboxen kann hier gesteuert werden.
   if not FileExists2( fPath + IMAPINDEX_FILENAME ) then
      fIndex.Rebuild( fPath, fStatus );
end;

destructor TImapMailbox.Destroy;
begin
     LogRaw( LOGID_DEBUG, 'TImapMailbox.Destroy' ); {MG}{ImapLog}
     WriteStatus;
     if Assigned(fIndex) then fIndex.Free;
     if fUsers.Count > 0 then
        LogRaw( LOGID_ERROR, 'TImapMailbox.Destroy: imap mailbox is still in use!' );
     fUsers.Free; // TODO: User direkt aufräumen oder warnen?
     CfgAccounts.IMAPMailboxLock( fPath, False );
     DeleteCriticalSection( fCritSection );

     inherited;
end;

function TImapMailbox.StrToMsgSet(s: String; UseUID: Boolean): TMessageSet;

   function SeqNumber( s: String ): Integer;
   var  i : Integer;
   begin
        if UseUID
           then Result := fIndex.GetUID( Status.Messages - 1 )
           else Result := Status.Messages;
        if s = '*' then exit;
        if s = '4294967295' // ugly workaround - we should have used u_int32
           then i := 2147483647
           else i := StrToInt( s );
        if i > Result
           then inc( Result )
           else Result := i
    end;

   function GetSet( s: String ): TMessageSet;
   var  i, j, Start, Finish : Integer;
   begin
        i := Pos( ':', s );
        if i > 0 then begin
           Start  := SeqNumber( copy( s, 1, i-1 ) );
           System.Delete( s, 1, i );
        end else Start := SeqNumber( s );
        Finish := SeqNumber( s );
        if Finish < Start then begin
           i := Finish;
           Finish := Start;
           Start := i;
        end;
        SetLength( Result, Finish - Start + 1 );
        j := 0;
        for i := Start to Finish do begin
           if UseUID
              then Result[j] := fIndex.GetIndex( i ) + 1
              else Result[j] := i;
           if (Result[j] > 0) and (Result[j] <= Status.Messages) then inc( j )
        end;
        SetLength( Result, j )
   end;

var  i : Integer;
begin
     SetLength( Result, 0 );
     s := TrimWhSpace( s );
     if s > '' then begin
        i := Pos( ',', s );
        while i > 0 do begin
           Result := JoinMessageSets( Result, GetSet( copy( s, 1, i-1 ) ) );
           System.Delete( s, 1, i );
           i := Pos( ',', s );
        end;
        Result := JoinMessageSets( Result, GetSet( s ) )
     end
end;

{MG}{Search-new}
function TImapMailbox.Search( SearchStruct: TIMAPSearch; UseUID: Boolean ): String;
var  FoundMessages : TMessageSet;
     i : Integer;
begin
     Result := '';
     LogRaw( LOGID_DETAIL, 'Searching messages in imap mailbox ' + Path + ' ...' );
     FoundMessages := Find( SearchStruct, StrToMsgSet( '1:*', False ) );
     for i := 0 to Length(FoundMessages) - 1 do
        if UseUID
            then Result := Result + ' ' + fIndex.GetUIDStr( FoundMessages[i] - 1 )
            else Result := Result + ' ' + IntToStr( FoundMessages[i] )
end;


function TImapMailbox.Find( Search: TIMAPSearch; MsgSet: TMessageSet ): TMessageSet;
var  Found : TMessageSet;
     i     : Integer;
begin
     SetLength( Result, 0 );
     SetLength( Found, Length(MsgSet) );
     for i := 0 to High(Found) do Found[i] := MsgSet[i];

     // do the fast searches first
     if Search.Sequence.Count > 0 then begin
        for i := 0 to Search.Sequence.Count - 1 do
           Found := FindMessageSets( Found, StrToMsgSet( Search.Sequence[i], False ), False );
        if Length( Found ) = 0 then exit
     end;
     if Search.UIDSequence.Count > 0 then begin
        for i := 0 to Search.UIDSequence.Count - 1 do
           Found := FindMessageSets( Found, StrToMsgSet( Search.UIDSequence[i], True ), False );
        if Length( Found ) = 0 then exit
     end;
     if Search.FlagsSet <> FLAGNONE then begin
        Found := FindFlags( Found, Search.FlagsSet, False );
        if Length( Found ) = 0 then exit
     end;
     if Search.FlagsUnset <> FLAGNONE then begin
        Found := FindFlags( Found, Search.FlagsUnset, True );
        if Length( Found ) = 0 then exit
     end;
     if (Search.Since > 0) or (Search.Before < High(Int64)) then begin
        Found := FindTimeStamp( Found, Search.Since, Search.Before );
        if Length( Found ) = 0 then exit
     end;
     if (Search.Larger > 0) or (Search.Smaller < High(Integer)) then begin
        Found := FindSize( Found, Search.Larger, Search.Smaller );
        if Length( Found ) = 0 then exit
     end;

     // slow searches: each message has to be read
     if (Search.SentSince > 0) or (Search.SentBefore < High(Int64)) or
        (Search.HeaderStrings.Count > 0) or (Search.BodyStrings.Count > 0) or
        (Search.TextStrings.Count > 0) then begin
        Found := FindContent( Found, Search.SentSince, Search.SentBefore,
                              Search.Charset, Search.HeaderStrings,
                              Search.BodyStrings, Search.TextStrings );
        if Length( Found ) = 0 then exit
     end;

     // inferior nested searches  (OR / NOT)
     if Search.Subs.Count > 0 then
        for i := 0 to Search.Subs.Count - 1 do with TSearchSub(Search.Subs[i]) do
           if Assigned( Sub2 )
              then Found := JoinMessageSets( Find( Sub1, Found ), Find( Sub2, Found ) )
              else Found := FindMessageSets( Found, Find( Sub1, Found ), True );

     SetLength( Result, Length(Found) );
     for i := 0 to High(Result) do Result[i] := Found[i];
end;

function TImapMailbox.FindMessageSets( MsgSet1, MsgSet2: TMessageSet;
                                       Exclude: Boolean ): TMessageSet;
// Returns messages that are part of MsgSet1 AND (not) MsgSet2
var  i, j, k : Integer;
     Found : Boolean;
begin
     SetLength( Result, Length(MsgSet1) );
     j := 0;
     for i := 0 to High( MsgSet1 ) do begin
        Found := False;
        for k := 0 to High( MsgSet2 ) do begin
           if ( MsgSet2[k] = MsgSet1[i] ) then begin
              Found := True;
              break
           end;
        end;
        if Found xor Exclude then begin
           Result[j] := MsgSet1[i];
           inc( j )
        end
     end;
     SetLength( Result, j )
end;

function TImapMailbox.JoinMessageSets( MsgSet1, MsgSet2: TMessageSet ): TMessageSet;
// Returns messages that are part of MsgSet1 OR MsgSet2
var  i, j, k : Integer;
     Unique  : Boolean;
begin
     SetLength( Result, Length(MsgSet1) + Length(MsgSet2) );
     j := Length(MsgSet1);
     for i := 0 to j-1 do Result[i] := MsgSet1[i];
     for i := 0 to High( MsgSet2 ) do begin
        Unique := True;
        for k := 0 to High( MsgSet1 ) do
           if MsgSet2[i] = MsgSet1[k] then begin
              Unique := False;
              break
           end;
        if Unique then begin
           Result[j] := MsgSet2[i];
           inc( j )
        end
     end;
     SetLength( Result, j )
end;

function TImapMailbox.FindFlags( MsgSet: TMessageSet; Flags: TFlagMask;
                                 Exclude: Boolean ): TMessageSet;
var  i, j : Integer;
begin
     SetLength( Result, Length(MsgSet) );
     j := 0;
     for i := 0 to High( MsgSet ) do
        if ( ( fIndex.GetFlags(MsgSet[i]-1) and Flags ) = Flags ) xor Exclude then begin
           Result[j] := MsgSet[i];
           inc( j )
        end;
     SetLength( Result, j )
end;

function TImapMailbox.FindTimeStamp( MsgSet: TMessageSet; After, Before: Int64 ): TMessageSet;
var  i, j   : Integer;
     MyDate : Int64;
begin
     SetLength( Result, Length(MsgSet) );
     j := 0;
     for i := 0 to High( MsgSet ) do begin
        MyDate := Trunc( UnixTimeToDateTime( fIndex.GetTimeStamp(MsgSet[i]-1) ) );
        if (MyDate > After) and (MyDate < Before) then begin
           Result[j] := MsgSet[i];
           inc( j )
        end
     end;
     SetLength( Result, j )
end;

function TImapMailbox.FindSize( MsgSet: TMessageSet; Min, Max: Integer ): TMessageSet;
var  i, j : Integer;
     SR   : TSearchRec;
begin
     SetLength( Result, Length(MsgSet) );
     j := 0;
     if Min < Max then begin
        for i := 0 to High( MsgSet ) do begin
           if SysUtils.FindFirst( fPath + fIndex.GetUIDStr(MsgSet[i]-1) + '.'+Def_Extension_Mail,
                                  faAnyFile, SR ) = 0 then begin
              if (SR.Size > Min) and (SR.Size < Max) then begin
                 Result[j] := MsgSet[i];
                 inc( j )
              end;
              SysUtils.FindClose( SR )
           end
        end
     end;
     SetLength( Result, j )
end;

function TImapMailbox.FindContent( MsgSet: TMessageSet; After, Before: Int64;
                                   Charset: String; HeaderList, BodyStrings,
                                   TextStrings: TStringList ): TMessageSet;

     function GetCharset( ContentType: String ): String;
     var  i : Integer;
     begin
          Result := '';
          ContentType := UpperCase( ContentType );
          i := Pos( 'CHARSET=', ContentType );
          if i > 0 then begin
             System.Delete( ContentType, 1, i+7 );
             Result := UpperCase( QuotedStringOrToken( ContentType ) )
          end
     end;

     function Has8BitChar( txt: String ): Boolean;
     var  i: Integer;
     begin
          Result := True;
          for i := 1 to Length( txt ) do if Ord( txt[i] ) > 127 then exit;
          Result := False
     end;

     function BadCombination( MyCharset: String; SearchStr: String ): Boolean;
     begin
          Result := False;
          MyCharset := UpperCase( MyCharset );
          if (MyCharset <> 'UTF-8') and (MyCharset <> 'UTF-7') then begin
             if (MyCharset = Charset) then exit;
             if not Has8BitChar( SearchStr ) then exit;
          end;
          Result := True;
          Log( LOGID_WARN, 'IMAPMailbox.Search.IncompatibleCharsets', 
             'IMAP SEARCH: Search charset (%s) and message charset (%s) differ. The current message is ignored.',
             [Charset,MyCharset] )
     end;

var  i, j, k, m : Integer;
     HdrValue   : String;
     HdrName    : String;
     MyMail     : TArticle;
     MyHeader   : String;
     MyString   : String;
     MyCharset  : String;
     MyDate     : Int64;
     NotFound   : Boolean;
begin
     SetLength( Result, Length(MsgSet) );
     j := 0;
     MyMail := TArticle.Create;
     try
        for i := 0 to High( MsgSet ) do begin
           MyMail.LoadFromFile( fPath + fIndex.GetUIDStr(MsgSet[i]-1)
                                +'.'+Def_Extension_Mail );
           NotFound := False;

           // Search headers
           for k := 0 to HeaderList.Count - 1 do begin
              m := Pos( ':', HeaderList[k] );
              HdrName  := Copy( HeaderList[k], 1, m );
              HdrValue := UpperCase( Copy( HeaderList[k], m+1, Length(HeaderList[k])-m ) );
              if HdrValue <> '' then begin
                 MyHeader := UpperCase( DecodeHeadervalue( MyMail.Header[HdrName], MyCharset ) );
                 if BadCombination( MyCharset, HdrValue ) then begin
                    NotFound := True;
                    break
                 end;
                 if Pos( HdrValue, MyHeader ) = 0 then begin
                    NotFound := True;
                    break
                 end
              end else begin
                 if not MyMail.HeaderExists( HeaderList[k] ) then begin
                    NotFound := True;
                    break
                 end
              end
           end;
           if NotFound then continue;

           // Search message date
           MyDate := Trunc( RfcDateTimeToDateTimeGMT( MyMail.Header['Date:'] ) );
           if (MyDate <= After) or (MyDate >= Before) then continue;

           if (BodyStrings.Count > 0) or (TextStrings.Count > 0) then begin
              MyCharset := GetCharset( MyMail.Header['Content-Type:'] );
              if BadCombination( MyCharset, BodyStrings.Text + TextStrings.Text )
                 then continue;

              // Search body text
              MyString := UpperCase( MyMail.FullBody );
              for k := 0 to BodyStrings.Count - 1 do begin
                 if Pos( BodyStrings[k], MyString ) = 0 then begin
                    NotFound := True;
                    break
                 end
              end;
              if NotFound then continue;

              // Search full text
              MyString := UpperCase( MyMail.FullHeader ) + #13#10 + MyString;
              for k := 0 to TextStrings.Count - 1 do begin
                 if Pos( TextStrings[k], MyString ) = 0 then begin
                    NotFound := True;
                    break
                 end
              end;
              if NotFound then continue;
           end;

           Result[j] := MsgSet[i];
           inc( j );
        end
     finally MyMail.Free end;
     SetLength( Result, j )
end;
{/Search-new}
end.
