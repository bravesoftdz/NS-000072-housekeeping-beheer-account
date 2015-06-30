{
	Beheer Accounts Cleanup

	
	
	VERSION:
	========
	
	Version		Date		Author		Description
	-------		---------	----------	----------------------------------
	04			2015-01-08	PVDH		Initial version in Pascal



	FLOW:
	=====
	
	Program
		ProgInit
		ProgRun
			Step1Export
				ProcessDomain
					CreateExportAccount
					CreateExportDcList
					CreateExportLastLogon
			Step2Process
				GetPosOfHeaderItem
				ProcessAccount
					IsValidAccount
					
					
		ProgDone

	
	
	PRCOEDURES AND FUNCTIONS:
	=========================
	
		procedure CreateExportAccount(strFnameAccount: string; strDomainNetbios: string; strBaseOu: string);
		procedure CreateExportDcList(strFnameDcList: string; strRootDn: string);
		procedure CreateExportLastLogon(strFnameLastLogon: string; strRootDse: string; strBaseOu: string);
		procedure ProgDone();
		procedure ProgInit();
		procedure ProgRun();
		procedure Step1Export();
		procedure Step2Process();
		function GetPosOfHeaderItem(searchHeaderItem: string): integer;
		function GetReadLastLogon(strSearchDn: string; dtCreated: TDateTime; dtLastLogonTimestamp: TDateTime): TDateTime;
		function IsValidAccount(sSam: string): boolean;
		
	
}


program BACleanup;



{$MODE OBJFPC} // Do not forget this ever
{$M+}



uses
	DateUtils,
	Process,
	SysUtils,
	StrUtils,
	UTextFile,
	UTextSeparated,
	USupportLibrary;


	
const	
	DAYS_DISABLE =						90;		// Disable accounts older then...
	DAYS_DELETE =						180;	// Delete accounts older then...
	ADS_UF_ACCOUNTDISABLE =				2;		// UserAccountControl bit for account disable
	ADS_UF_DONT_EXPIRE_PASSWD = 		65536;	// UserAccountControl bit for Password Never Expires
	//SECS_PER_DAY = 					86400;	// Number of seconds per day (24 * 60 * 60 = 86400)

	FNAME_EXPORT = 					 	'export.tmp';
	FNAME_ACTION = 						'action.cmd';
	FNAME_DCLIST = 						'export-dc-list.tmp';
	FNAME_ACCOUNT = 					'export-account.tmp';
	FNAME_LASTLOGON = 					'export-last-logon.tmp'; 
	FNAME_CONFIG = 						'bacleanup.conf';
	FNAME_LOG = 						'log.tsv';
	SEPARATOR = 						#9;		// Separator of export file is a TAB, Chr(9) or #9
	
	
var
	//giSecDisable: LongInt;
	//giSecDelete: LongInt;
	//giTotalDisable: integer;
	//giTotalDelete: integer;
	
	gdtNow: TDateTime;
	//tsvExport: CTextSeparated;	
	//tsvLog: CTextSeparated;
	//txtBatch: CTextFile;
	gsBatchNumber: string; 			// Contains the batch number in format YYYYMMDDHHMMSS
	garrHeader: TStringArray;
	gintSecondsDisable: integer;
	gintSecondsDelete: integer;
	//strDn: string;
	//dtLatest: TDateTime;
	


function GetDnsDomainFromDn(sDn: string): string;
{
	Extract the DNS domain name from a DN
	
	CN=Jurgen.Caspers,OU=Normal,OU=Accounts,OU=RBAC,DC=REC,DC=NSINT > rec.nsint
}

var
	p: integer;
	r: string;
begin
	//WriteLn('GetDnsDomainFromDn(): ', sDn);
	p := Pos('DC=', sDn);
	//WriteLn(p);
	r := RightStr(sDn, length(sDn) - p + 1);
	//WriteLn(r);
	
	r := ReplaceText(r, 'DC=', '');
	r := ReplaceText(r, ',', '.');
	
	GetDnsDomainFromDn := r;
end; // of function GetDnsDomainFromDn


function GetRootDseFromDn(sDn: string): string;
{
	Extract the RootDse name from a DN
	
	CN=Jurgen.Caspers,OU=Normal,OU=Accounts,OU=RBAC,DC=REC,DC=NSINT > DC=REC,DC=nsint
}
var
	p: integer;
	r: string;
begin
	//WriteLn('GetRootDseFromDn(): ', sDn);
	p := Pos('DC=', sDn);
	//WriteLn(p);
	r := RightStr(sDn, length(sDn) - p + 1);
	//WriteLn(r);
		
	GetRootDseFromDn := r;
end; // of function GetRootDseFromDn



function IsValidAccount(sSam: string): boolean;
type
	TPrefix = array[0..10] of string;
var
	aPrefix: TPrefix;
	x: integer;
	r: boolean;
begin
	r := false;

	aPrefix[0] := 'BEH';
	aPrefix[1] := 'NSA';
	aPrefix[2] := 'NSS';
	aPrefix[3] := 'NSI';
	aPrefix[4] := 'KPN';
	aPrefix[5] := 'GTN';
	aPrefix[6] := 'HP';
	aPrefix[7] := 'EDS';
	aPrefix[8] := 'CSC';
	aPrefix[9] := 'ADB';
	aPrefix[10] := 'REC';
	
	for x := 0 to Length(aPrefix) - 1 do
	begin
		//WriteLn(x, ': ', aPrefix[x]);
		if Pos(aPrefix[x] + '_', UpperCase(sSam)) = 1 then
			r := true;
	end;
	IsValidAccount := r;
end; // of function IsValidAccount



function GetSupportOrg(sSam: string): string;
{
	Returns the support organisation of the beheer account
}

var
	sPrefix: string;
	r: string;
begin
	//WriteLn(Pos('_', sSam));
	
	sPrefix := LeftStr(sSam, Pos('_', sSam) - 1);
	//WriteLn(sPrefix);
	
	case UpperCase(sPrefix) of
		'NSA', 'NSS', 'NSI', 'BEH', 'REC', 'ADB': r := 'NS';
		'KPN', 'GTN': r:= 'KPN';
		'HP', 'EDS': r := 'HP';
		'CSC': r := 'CSC';
	else
		r:= 'UNKNOWN';
	end; // of Case sPrefix of
	GetSupportOrg := r;
end; // of function GetSupportOrg



function IsDisabled(iUac: LongInt): boolean;
	{'
	''	Check the disabled status of an account using the UAC
	''	(User Account Control Value)
	''	
	''	Magic line: If (intUac And ADS_UF_ACCOUNTDISABLE) = ADS_UF_ACCOUNTDISABLE Then DISABLED
	''
	''	Returns
	''		True: 	Account is locked
	''		False:	Account is not locked
	'}
begin;
	if (iUac and ADS_UF_ACCOUNTDISABLE) = ADS_UF_ACCOUNTDISABLE then
		IsDisabled := true
	else
		IsDisabled := false;
end; // of function IsDisabled
	

{	
procedure DoCommandDisable(sDn: string; sDesc: string);
var
	sCmd: string;
begin
	// First update the description field Description
	sCmd := 'dsmod.exe user "' + sDn + '" -desc "BA HOUSEKEEPING ' + gsBatchNumber + ', ' + sDesc + '"';
	//txtBatch.WriteToFile(sCmd);

	// Secondly disable the account using DSMOD.EXE to disable the account
	sCmd := 'dsmod.exe user "' + sDn + '" -disabled yes';
	//txtBatch.WriteToFile(sCmd);
	
	// Add a blank line
	//txtBatch.WriteToFile('');
end; // of procedure WriteDisable
}

procedure DoCommandDelete(sDn: string; sSam: string);
var
	sCmd: string;
begin
	sCmd := 'adfind.exe -b "' + sDn + '" ';
	sCmd := sCmd + '-tdcs -tdcsfmt "%%YYYY%%-%%MM%%-%%DD%% %%HH%%:%%mm%%:%%ss%%" ';
	sCmd := sCmd + '-tdcgt -tdcfmt "%%YYYY%%-%%MM%%-%%DD%% %%HH%%:%%mm%%:%%ss%%" ';
	sCmd := sCmd + '>>userinfo\' + sSam + '.txt';
	//txtBatch.WriteToFile(sCmd);
	
	sCmd := 'dsrm.exe "' + sDn + '" -noprompt';
	//txtBatch.WriteToFile(sCmd);
	
	// Add a blank line
	//txtBatch.WriteToFile('');
end; // of procedure WriteDelete


{
procedure WriteToLog(sDn: string; sSam: string; dtCalc: TDateTime; sWhichUsed: string; iAgoDays: integer; sAction: string; sMessage: string);

var
	sDomain: string;
	sSupportOrg: string;
begin
	// Get the DNS domain name from a DN
	sDomain := GetDnsDomainFromDn(sDn);
	// Get the Support Organization for an SAM account.
	sSupportOrg := GetSupportOrg(sSam);
	
	//tsvLog.WriteToFile(sDomain + #9 + sSupportOrg + #9 + sSam + #9 + DateTimeToStr(dtCalc) + #9 + sWhichUsed + #9 + IntToStr(iAgoDays) + #9 + sAction + #9 + sMessage);
end; // of procedure WriteToLog
}



function DateDiffSec(Date1, Date2: TDateTime): int64;
{
	Calculate the number of seconds between 2 dates.
	
	Result:
		< 0		Date2 is newer then Date1
		> 0		Date1 is newer then Date2
		= 0		Date1 is the same as Date2
}
var
	r: integer;
begin
	r := Trunc(86400.0 * (Date1 - Date2)); // Number of seconds between 2 dates
	//WriteLn('DateDiffSec(): Date1=', DateTimeToStr(Date1), ' - Date2=', DateTimeToStr(Date2), ' = ', r);
	DateDiffSec := r;
end; // of function DateDiffSec().



function StrToDateTimeCheck(strDateTime: string): TDateTime;
{
	Convert a date time formatted string to a TDateTime variable
	Check before conversion of the strDateTime contains data, returns 1899-12-30 00:00:00 (= 0)
	Check before conversion of the strDateTime doesn't contain a 0000-00-00 00:00:00, returns 1899-12-30 00:00:00 (= 0)
	Otherwise convert using DateTimeToStr
}
var
	r: TDateTime;
begin
	// Check if the strLastLogonTimestamp contains a valid date
	if (Length(strDateTime) = 0) or (strDateTime = '0000-00-00 00:00:00') then
		// Invalid date, set the date time to 1899
		r := StrToDateTime('1899-12-30 00:00:00')
	else
		// Valid date time, convert to DateTime variable
		r := StrToDateTime(strDateTime);
		
	StrToDateTimeCheck := r;
end; // of function DateTimeToStrCheck



function GetReadLastLogon(strSearchDn: string; strCreated: string; strLastLogonTimestamp: string): TDateTime;
{
	Read the FNAME_LASTLOGON file and returns the latest lastLogon from a strSearchDn
	
	strSearchDn					DN of the the account
	strCreated					Account creation Time Date
	strLastLogonTimestamp		The latest synced date time of the last login.
	
	1) Latest is the dtCreated
	
	2) If the dtLastLogonTimestamp is newer then the dtCreated then that will be the latest.
	
	3) If you find a newer LastLogon date per domain controller, that will become the lateste
	
}
var
	f: TextFile;
	intLineCount: integer;
	strLine: AnsiString;
	arrLine: TStringArray;
	dtLatest: TDateTime;
	//x: integer;
	dtFound: TDateTime;
	dtCreated: TDateTime;
	intSecondsBetween: integer;
	dtLastLogonTimestamp: TDateTime;
begin
	intLineCount := 0;

	//WriteLn('GetReadLastLogon():');
	//WriteLn('            strSearchDn : [', strSearchDn, ']');
	//WriteLn('             strCreated : ', strCreated);
	//WriteLn('  strLastLogonTimestamp : ', strLastLogonTimestamp);
	
	// Convert the strCreated and strLastLogonTimestamp to a DateTime variable.
	dtCreated := StrToDateTimeCheck(strCreated);
	dtLastLogonTimestamp := StrToDateTimeCheck(strLastLogonTimestamp);
	
	// Latest date time is now the created date time.
	dtLatest := dtCreated; 
	
	// Check if the dtLastLogonTimestamp is newer that the creation date time.
	if DateDiffSec(dtLatest, dtLastLogonTimestamp) > 0 then
		// dtLatest becomes the dtLastLogonTimestamp when it's newer
		dtLatest := dtLastLogonTimestamp;
	
	AssignFile(f, FNAME_LASTLOGON);
	{I+}
	try 
		Reset(f);
		repeat
			Inc(intLineCount);
			ReadLn(f, strLine);
			// Skip all lines that are not an Distinguished Name (DN) (starting with 'CN=').
			//WriteLn(intLineCount, ': ', strLine);
			if Pos(strSearchDn, strLine) > 0 then
			begin
				// Only process the lines that contain the DN of the user.
				//WriteLn('strLine=', strLine);
					
				SetLength(arrLine, 0);
				arrLine := SplitString(strLine, #9);
				
				{
				for x := 0 to High(arrLine) do
				begin
					WriteLn(x, ':[', arrLine[x], ']    LENGTH=', Length(arrLine[x]));
				end;
				}
				
				if (Length(arrLine[1]) <> 0) and (arrLine[1] <> '0000-00-00 00:00:00') then
				begin
					// There is a date found in the line
					//WriteLn('FOUND A DATE!');
					dtFound := StrToDateTime(arrline[1]);
					
					intSecondsBetween := DateDiffSec(dtFound, dtLatest);
					//WriteLn(' Seconds between dtLatest and dtLatest: ', intSecondsBetween);
					if intSecondsBetween > 0 then
					begin
						// A new latest date time
						dtLatest := dtFound;
						//WriteLn('dtLatest has become: ', DateTimeToStr(dtLatest), ', because its newer then the current dtLatest.');
					end;
				end;
			end;
		until Eof(f);
		CloseFile(f);
	except
		on E: EInOutError do
			WriteLn('File ', FNAME_LASTLOGON, ' handeling error occurred, Details: ', E.ClassName, '/', E.Message);
	end;
	
	GetReadLastLogon := dtLatest;
end; // of function GetReadLastLogon



procedure ProcessAccount(strDn: string; strSam: string; dtLatest: TDateTime; intUac: integer);
var
	intSecondsAgo: integer;
begin
	WriteLn;
	WriteLn(LeftStr('ProcessAccount():' + StringOfChar('-', 80), 80));
	WriteLn('    strDn : ', strDn);
	WriteLn('   strSam : ', strSam);
	WriteLn(' dtLatest : ', DateTimeToStr(dtLatest));
	WriteLn('   intUac : ', intUac);
	
	
	if IsValidAccount(strSam) = false then
	begin
		Writeln(strSam + ' is not an valid account, skipping...');
		Exit;
	end;
	
	intSecondsAgo := DateDiffSec(Now(), dtLatest);
	WriteLn('       intSecondsAgo : ', intSecondsAgo:9, ' = ', (intSecondsAgo / 86400):4:0, ' days');
	WriteLn('   gintSecondsDelete : ', gintSecondsDelete:9, ' = ', (gintSecondsDelete / 86400):4:0, ' days');
	WriteLn('  gintSecondsDisable : ', gintSecondsDisable:9, ' = ', (gintSecondsDisable / 86400):4:0, ' days');
	
	if intSecondsAgo > gintSecondsDelete then
	begin
		WriteLn('This account is not used for more then ', DAYS_DELETE, ' days, action: DELETE');
	end
	else 
	begin
		if	intSecondsAgo > gintSecondsDisable then
		begin
			WriteLn('This account is not used for more then ', DAYS_DISABLE, ' days, action: DISABLE');
			if IsDisabled(intUac) = false then
				WriteLn('Account is still active, disable it now!')
			else
				WriteLn('Account is already disabled.');
		end
		else
			WriteLn('No action needed!');
	end;
end; // of procedure ProcessAccount



function GetPosOfHeaderItem(searchHeaderItem: string): integer;
{
	Get the position of 'searchHeaderItem' in  the header array 'garrHeader'.
	Returns a integer of the position when found.
	Returns  -1 when no found.
}
var
	x: integer;
	//r: integer;
begin
	GetPosOfHeaderItem := -1;
	for x := 0 to Length(garrHeader) do
	begin
		//WriteLn(#9, x, #9, searchHeaderItem, #9, garrHeader[x]);
		if searchHeaderItem = garrHeader[x] then
		begin
			GetPosOfHeaderItem := x;
			Break;
		end;
	end;
end; // of function GetPosOfHeaderItem()



procedure Step2Process();
var
	arrLine: TStringArray;
	f: TextFile;
	intLineCount: integer;
	intPosDn: integer;
	intPosCreated: integer;
	intPosUac: integer;
	intPosSam: integer;
	intPosLastLogonTimestamp: integer;
	strLine: AnsiString;
	strSam: string;
	strDn: string;
	//dtCreated: TDateTime;
	strCreated: string;
	strLastLogonTimestamp: string;
	//dtLastLogonTimestamp: TDateTime;
	intUac: integer;
	dtLatest: TDateTime;
begin
	WriteLn;
	WriteLn(LeftStr('Step2Process():' + StringOfChar('-', 80), 80));
	
	intLineCount := 0;
	
	AssignFile(f, FNAME_ACCOUNT);
	{I+}
	try 
		Reset(f);
		repeat
			Inc(intLineCount);
			ReadLn(f, strLine);
			//WriteLn(intLineCount, ': ', strLine);
			
			if intLineCount = 1 then
			begin
				// Determine on the first line, the header where all the data is located.
				WriteLn('HEADER!!', intLineCount, ': ', strLine);
				SetLength(garrHeader, 0); // Initialize the array space for the header.
				garrHeader := SplitString(strLine, SEPARATOR); // Split the line into an garrHeader array.
				
				intPosDn := GetPosOfHeaderItem('dn');
				intPosCreated := GetPosOfHeaderItem('whenCreated');
				intPosUac := GetPosOfHeaderItem('userAccountControl');
				intPosSam := GetPosOfHeaderItem('sAMAccountName');
				intPosLastLogonTimestamp := GetPosOfHeaderItem('lastLogontimeStamp');
			end
			
			else
			//if (intLineCount > 1) and (LeftStr(strLine, 3) = 'CN=') then
			begin
				// Only process lines that start with 'CN='.
				//WriteLn(intLineCount, ': ', strLine);
				SetLength(arrLine, 0);  // Initialize the array for the current line.
				arrLine := SplitString(strLine, SEPARATOR);
				
				strDn := arrLine[intPosDn];
				strSam := arrLine[intPosSam];
				//dtCreated := StrToDateTime(arrLine[intPosCreated]);
				//dtLastLogonTimestamp := StrToDateTime(arrLine[intPosLastLogonTimestamp]);
				intUac := StrToInt(arrLine[intPosUac]);
				
				strCreated := arrLine[intPosCreated];
				strLastLogonTimestamp := arrLine[intPosLastLogonTimestamp];
				
				// WriteLn('PROCESSING LINE ', intLineCount, ': ', strDn, #9, DateTimeToStr(dtCreated), #9, intUac);
				//WriteLn(strDn, #9, strCreated, #9, strLastLogonTimestamp);
				// Get the real latest action on the account.
				dtLatest := GetReadLastLogon(strDn, strCreated, strLastLogonTimestamp);
				// Process the line with data.
				ProcessAccount(strDn, strSam, dtLatest, intUac);
			end;
		until Eof(f);
		CloseFile(f);
	except
		on E: EInOutError do
			WriteLn('File ', FNAME_ACCOUNT, ' handeling error occurred, Details: ', E.ClassName, '/', E.Message);
	end;
end; // of procedure Step2Process();



procedure CreateExportLastLogon(strFnameDcList: string; strFnameLastLogon: string; strBaseOu: string);
{
	Check on each DC found in strFnameDcList of strRootDse the LastLogon value for all accounts found in strBaseOu,
	store in strFnameLastLogon.
}
var
	f: TextFile;
	strLine: string;
	p: TProcess;
	c: AnsiString;
begin
	WriteLn;
	WriteLn(LeftStr('CreateExportLastLogon():' + StringOfChar('-', 80), 80));
	WriteLn('     strFnameDcList : ', strFnameDcList);		// File name of dc list
	WriteLn('  strFnameLastLogon : ', strFnameLastLogon);	// File of last logons
	WriteLn('          strBaseOu : ', strBaseOu);			// OU=accounts,DC=domain,DC=ext
	
	AssignFile(f, strFnameDcList);
	{I+}
	try 
		Reset(f);
		repeat
			ReadLn(f, strLine);
			WriteLn(strLine);
			
			// Export from all DC's of domain strBaseOu the lastLogon date time value.
			
			c := 'adfind.exe ';
			c := c + '-h ' + EncloseDoubleQuote(strLine) + ' ';
			c := c + '-b ' + EncloseDoubleQuote(strBaseOu) + ' ';
			c := c + '-f "' + #38 + '(objectClass=user)(objectCategory=person)" ';
			c := c + 'lastLogon ';
			c := c + '-jtsv -csvnoq ';
			c := c + '-tdcs -tdcsfmt "%YYYY%-%MM%-%DD% %HH%:%mm%:%ss%" ';
			c := c + '>>' + strFnameLastLogon;
			WriteLn(c);
			
			// Setup the process to be executed.
			p := TProcess.Create(nil);
			p.Executable := 'cmd.exe'; 
			p.Parameters.Add('/c ' + c);
			// 1) Wait until the process is finished and 
			// 2) do not show output to the console.
			p.Options := [poWaitOnExit, poUsePipes]; 
			p.Execute;		// Execute the command.
			
		until Eof(f);
		CloseFile(f);
	except
		on E: EInOutError do
			WriteLn('File ', strFnameDcList, ' handeling error occurred, Details: ', E.ClassName, '/', E.Message);
	end;
end; // of procedure CreateExportLastLogon().



procedure CreateExportDcList(strFnameDcList: string; strRootDn: string);
{
	Create a file with all the FQDN's of DC servers of domain specified in strRootDn.
}
var
	p: TProcess;
	c: AnsiString;
begin
	WriteLn;
	WriteLn(LeftStr('CreateExportDcList():' + StringOfChar('-', 80), 80));
	c := 'adfind.exe -b ' + EncloseDoubleQuote(strRootDn) + ' -sc dclist >' + FNAME_DCLIST;

	WriteLn('c=', c);
	
	// Setup the process to be executed.
	p := TProcess.Create(nil);
	p.Executable := 'cmd.exe'; 
    p.Parameters.Add('/c ' + c);
	// 1) Wait until the process is finished and 
	// 2) do not show output to the console.
	p.Options := [poWaitOnExit, poUsePipes]; 
	p.Execute;		// Execute the command.
end; // of procedure CreateExportDcList();



procedure CreateExportAccount(strFnameAccount: string; strDomainNetbios: string; strBaseOu: string);
{
	Create a TSV with the account values in strFnameAccount of domain strDomainNetbios, started from strBaseOu.
}
var
	p: TProcess;
	c: AnsiString;
begin
	WriteLn;
	WriteLn(LeftStr('CreateExportAccount():' + StringOfChar('-', 80), 80));
	
	// adfind.exe -b %%c,%%a -binenc -f "&(objectClass=user)(objectCategory=person)" sAMAccountName displayName givenName sn cn title description homeDirectory profilePath userAccountControl lastLogontimeStamp pwdLastSet whenCreated -jtsv -tdcs -tdcgt -tdcfmt "%%YYYY%%-%%MM%%-%%DD%% %%HH%%:%%mm%%:%%ss%%" -tdcsfmt "%%YYYY%%-%%MM%%-%%DD%% %%HH%%:%%mm%%:%%ss%%" >>%LOGPATH%

	c := 'adfind.exe -b ' + EncloseDoubleQuote(strBaseOu) + ' ';
	c := c + '-f "' + #38 + '(objectClass=user)(objectCategory=person)" ';
	c := c + 'sAMAccountName description userAccountControl userPrincipalName lastLogontimeStamp whenCreated ';
	c := c + '-jtsv -csvnoq ';
	c := c + '-tdcgt -tdcfmt "%YYYY%-%MM%-%DD% %HH%:%mm%:%ss%" ';
	c := c + '-tdcs -tdcsfmt "%YYYY%-%MM%-%DD% %HH%:%mm%:%ss%" ';
	c := c + '>>' + strFnameAccount;

	WriteLn(c);
	
	p := TProcess.Create(nil);
	p.Executable := 'cmd.exe'; 
    p.Parameters.Add('/c ' + c);
	// 1) Wait until the process is finished and 
	// 2) do not show output to the console.
	p.Options := [poWaitOnExit, poUsePipes]; 
	p.Execute;		// Execute the command.
	
	p.Destroy;		// Destroy the process.
end; // of procedure CreateExportAccount().



procedure ProcessDomain(strFnameAccount: string; strRootDn: string; strBaseOu: string; strDomainNetbios: string);
begin
	WriteLn;
	WriteLn(LeftStr('ProcessDomain():' + StringOfChar('-', 80), 80));
	WriteLn('   strFnameAccount : ', strFnameAccount);		// File name of accounts
	WriteLn('        strRootDse : ', strRootDn);			// DC=domain,DC=ext
	WriteLn('         strBaseOu : ', strBaseOu);			// OU=accounts,DC=domain,DC=ext
	WriteLn('  strDomainNetbios : ', strDomainNetbios);		// DOMAINNAME
	
	CreateExportAccount(FNAME_ACCOUNT, strDomainNetbios, strBaseOu);
	CreateExportDcList(FNAME_DCLIST, strRootDn);
	CreateExportLastLogon(FNAME_DCLIST, FNAME_LASTLOGON, strBaseOu);
	
end; // of procedure ProcessDomain()



procedure Step1Export();
var
	f: TextFile;
	strLine: string;
	arrLine: TStringArray;
begin
	WriteLn;
	WriteLn(LeftStr('Step1Export():' + StringOfChar('-', 80), 80));
	
	AssignFile(f, FNAME_CONFIG);
	{I+}
	try 
		Reset(f);
		repeat
			// Process  every line in the .conf file.
			ReadLn(f, strLine);
			WriteLn(strLine);
			
			arrLine := SplitString(strLine, '|');
			ProcessDomain(FNAME_ACCOUNT, arrLine[0], arrLine[1] + ',' + arrLine[0], arrLine[2]);
		until Eof(f);
		CloseFile(f);
	except
		on E: EInOutError do
			WriteLn('File ', FNAME_CONFIG, ' handeling error occurred, Details: ', E.ClassName, '/', E.Message);
	end;
end; // of procedure Step1Export().



procedure ProgTest();
var
	strDn: string;
	dtCreated: TDateTime;
begin
	//WriteLn(GetLatestLogonDate('CN=HP_Ian.Webermann,OU=HP,OU=Beheer,DC=prod,DC=ns,DC=nl'));
	//strDn := 'CN=Perry.vandenHondel,OU=Accounts,DC=prod,DC=ns,DC=nl';
	//dtLatest := GetLatestLogonDate(strDn);
	//WriteLn(' *** Latest logon date time for:', strDn, ': ', DateTimeToStr(dtLatest));
	
	
	strDn := 'CN=KPN_P.Krishnachar,OU=KPN,OU=Beheer,DC=test,DC=ns,DC=nl';
	dtCreated := StrToDateTime('2014-06-18 13:03:30');
	//WriteLn(DateTimeToStr(GetReadLastLogon(strDn, dtCreated)));
	
	strDn := 'CN=BEH_Gilroy.Weiland,OU=BEH,OU=Beheer,DC=test,DC=ns,DC=nl';
	dtCreated := StrToDateTime('2008-3-17 09:52:03');
	//WriteLn(DateTimeToStr(GetReadLastLogon(strDn, dtCreated)));
	
	
	
	strDn := 'CN=BEH_WMIScanProject,OU=Admin,OU=Beheer,DC=prod,DC=ns,DC=nl';
	dtCreated := StrToDateTime('2007-03-08 11:13:50');
	//WriteLn(DateTimeToStr(GetReadLastLogon(strDn, dtCreated)));
	
	strDn := 'CN=BEH_Perry.vdHondel,OU=Admin,OU=Beheer,DC=prod,DC=ns,DC=nl';
	dtCreated := StrToDateTime('2011-10-10 13:39:41');
	//WriteLn(DateTimeToStr(GetReadLastLogon(strDn, dtCreated)));

end; // of procedure ProgTest()



procedure ProgInit();
{
var
	sFolderBatch: string;
}
begin
	gdtNow := Now();
	
	WriteLn('Now: ' + DateTimeToStr(gdtNow));
	
	gsBatchNumber := GetDateFs(false); // + GetTimeFs();
	
	gintSecondsDisable := DAYS_DISABLE * 86400; // seconds is 24 hours & 60 min * 60 sec = 86400.
	gintSecondsDelete := DAYS_DELETE * 86400;
	
end; // of procedure ProgInit()



procedure ProgRun();
begin
	WriteLn;
	WriteLn(LeftStr('ProgRun():' + StringOfChar('-', 80), 80));
	
	// Delete any previous export file.
	DeleteFile(FNAME_ACCOUNT);
	DeleteFile(FNAME_LASTLOGON);
	
	Step1Export();		// Step 1 Exports all the data to files.
	Step2Process();		// Step 2 Processes these files.
end; // of procedure ProgRun()



procedure ProgDone();
begin
	WriteLn('Program completed!');
end; // of procedure ProgDone()
	


begin
	ProgInit();
	ProgRun();
	//ProgTest();
	ProgDone();
end. // of program BACleanup