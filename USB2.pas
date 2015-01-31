unit USB2;

interface

uses
  System.SysUtils, System.Classes,System.SyncObjs,Generics.Collections,System.DateUtils,System.Types,
  {$IFDEF ANDROID}
  android.hardware.usb.HID
  {$ENDIF}
  ;

const
  INIFILENAME = 'settings.ini';

type
  TReport = packed record
    ReportID: byte;
    Data:    array [0..15] of byte;
    //Data:    array of byte;
  end;

  TUSBController = class(TObject)
    HidCtrl       : TJvHidDevice;
    FaultCounter  : word;
    Serial        : string;
    LocalDataTimer: TEvent;
    LocalData     : TReport;
  public
    constructor Create(HidDev: TJvHidDevice);
    destructor Destroy;
    procedure ShowRead(HidDev: TJvHidDevice; ReportID: Byte;const Data: Pointer; Size: Word);
  end;

  TUSBList = TObjectList<TUSBController>;

  TUSBEvent  = procedure(Sender: TObject;datacarrier:integer) of object;

  TUSB=class
  private
    HidCtl:TJvHidDeviceController;

    AUSBList : TUSBList;

    FErrors:TStringList;
    FInfo:TStringList;
    FEmulation:boolean;

    FEnabled: Boolean;

    MaxErrors:word;

    FOnUSBDeviceChange: TUSBEvent;

    FIniFileFullPath:string;

    MaxPositions:word;

    procedure AddErrors(data:string);
    function  GetErrors:String;
    procedure AddInfo(data:string);
    function  GetInfo:String;
    procedure SetEnabled(Value: Boolean);

    function  HidReadWrite(Ctrl: TUSBController; ReadOnly:boolean):boolean;

    procedure DeviceArrival(HidDev: TJvHidDevice);
    procedure DeviceRemoval(HidDev: TJvHidDevice);
    procedure DeviceChange(Sender:TObject);

    function  CheckAddressNewer(Ctrl: TUSBController):integer;
    function  CheckParameters(board:word):boolean;overload;

    function  ReadSerial(Ctrl: TUSBController):string;

    procedure HandleCRCError(HidCtrl: TJvHidDevice);overload;

    function  FGetSerial(board:word):string;
  public
    constructor Create;
    destructor Destroy;override;

    property  Emulation:boolean read FEmulation;

    property  Errors:String read GetErrors;
    property  Info:String read GetInfo;

    property  Enabled: Boolean read FEnabled write SetEnabled;

    property  OnUSBDeviceChange: TUSBEvent read FOnUSBDeviceChange write FOnUSBDeviceChange;

    property  GetSerial[board: word]: string read FGetSerial;

    property Controller:TJvHidDeviceController read HidCtl;
  end;


implementation

uses
  System.IOUtils,
  IniFiles,
  StrUtils;

type
  TCommands = (
	  CMD_get_serial=100,
  	CMD_set_serial=101
  );

const
  Vendor                        = $04D8;
  Product                       = $003F;

  ErrorDelay                    = 100;
  USBTimeout                    = 2000;

constructor TUSBController.Create(HidDev: TJvHidDevice);
begin
  Inherited Create;
  HidCtrl:=HidDev;
  LocalDataTimer:=TEvent.Create(nil, true, false, '');
  LocalDataTimer.ResetEvent;
  if HidCtrl<>nil then
  begin
    //disable for now on Android !!
    HidCtrl.OnData:=nil;
    //HidCtrl.OnData:=ShowRead;
  end;
end;

destructor TUSBController.Destroy;
begin
  HidCtrl.OnData:=nil;
  LocalDataTimer.Free;
  Inherited Destroy;
end;

procedure TUSBController.ShowRead(HidDev: TJvHidDevice; ReportID: Byte;const Data: Pointer; Size: Word);
var
  x: Integer;
begin
  LocalData.ReportID:=ReportID;
  for x := Low(LocalData.Data) to High(LocalData.Data) do
  begin
    LocalData.Data[x]:=byte(PByte(Data)[x]);
  end;
  LocalDataTimer.SetEvent;
end;

constructor TUSB.Create;
var
  Ini: TIniFile;
  x:integer;
begin
  inherited Create;

  //System.IOUtils.tpath.GetDocumentsPath       -  /data/data/com.myapp.app1/files
  //System.IOUtils.tpath.GetSharedDocumentsPath -  /storage/emulated/0/Android/data/com.myapp.app1/files
  //System.IOUtils.tpath.GetPublicPath          -  /storage/emulated/0/Android/data/com.myapp.app1/files
  //System.IOUtils.tpath.GetHomePath            -  /data/data/com.myapp.app1/files
  FIniFileFullPath:=System.IOUtils.TPath.Combine(System.IOUtils.tpath.GetHomePath,INIFILENAME);

  FErrors:=TStringList.Create;
  FInfo:=TStringList.Create;

  AUSBList      := TUSBList.Create(false);

  FEmulation    := True;

  MaxErrors     := 1;

  Ini           := TIniFile.Create(FIniFileFullPath);
  try
    MaxErrors   := Ini.ReadInteger( 'General', 'NumError', MaxErrors );
  finally
    Ini.Free;
  end;

  HidCtl:=TJvHidDeviceController.Create(nil);
  {$IFDEF ANDROID}
  HidCtl.OnDeviceChange:=DeviceChange;
  {$ELSE}
  HidCtl.OnArrival:= DeviceArrival;
  HidCtl.OnRemoval:= DeviceRemoval;
  {$ENDIF}
end;

destructor TUSB.Destroy;
var
  board:word;
begin
  if AUSBList.Count>0 then
  begin
    for board:=Pred(AUSBList.Count) downto 0  do
    begin
      if Assigned(AUSBList.Items[board].HidCtrl) then HidCtl.CheckIn(AUSBList.Items[board].HidCtrl);
      AUSBList.Items[board].Destroy;
    end;
  end;
  AUSBList.Free;

  HidCtl.Free;
  FErrors.Free;
  FInfo.Free;
  inherited Destroy;
end;

procedure TUSB.SetEnabled(Value: Boolean);
begin
  if Value <> FEnabled then
  begin
    FEnabled := Value;
    HidCtl.Enabled:=FEnabled;
  end;
end;

function TUSB.HidReadWrite(Ctrl: TUSBController; ReadOnly:boolean):boolean;
var
  error:boolean;
  Written:DWORD;
  x:integer;
  Err:DWORD;
begin
  error:=False;

  if NOT Assigned(Ctrl.HidCtrl) then
  begin
    result:=False;
    exit;
  end;

  if Assigned(Ctrl.HidCtrl) then
  begin
    Ctrl.HidCtrl.FlushQueue;
    if (NOT ReadOnly) then
    begin
      if Assigned(Ctrl.HidCtrl.OnData) then Ctrl.LocalDataTimer.ResetEvent;
    end;
    error:=(NOT Ctrl.HidCtrl.WriteFile(Ctrl.LocalData, Ctrl.HidCtrl.Caps.OutputReportByteLength, Written));
    if (error) then
    begin
      Err := GetLastError;
      AddErrors(Format('USB normal write error: %s (%x)', [SysErrorMessage(Err), Err]));
    end;
    if (NOT error) AND (NOT ReadOnly) then
    begin
      error:=True;
      if Assigned(Ctrl.HidCtrl.OnData) then
      begin
        if Ctrl.LocalDataTimer.WaitFor(USBTimeout) = wrSignaled
           then error:=False
           else
           begin
             FillChar(Ctrl.LocalData, SizeOf(Ctrl.LocalData), 0);
             AddErrors('USB thread read timeout !!');
           end;
      end
      else
      begin
        error:=(NOT Ctrl.HidCtrl.ReadFile(Ctrl.LocalData, Ctrl.HidCtrl.Caps.InputReportByteLength, Written));
        if error then
        begin
          FillChar(Ctrl.LocalData, SizeOf(Ctrl.LocalData), 0);
          Err := GetLastError;
          AddErrors(Format('USB normal read error: %s (%x)', [SysErrorMessage(Err), Err]));
        end;
      end;
    end;
  end;

  result:=error;

end;


procedure TUSB.DeviceRemoval(HidDev: TJvHidDevice);
var
  board:integer;
begin
  AddInfo('Device removal. VID: '+InttoStr(HidDev.Attributes.VendorID)+'. PID: '+InttoStr(HidDev.Attributes.ProductID)+'.');
  if ((HidDev.Attributes.VendorID = Vendor) AND
      (HidDev.Attributes.ProductID = Product) ) then
  begin
    for board:=0 to AUSBList.Count-1 do
    begin
      if ((Assigned(AUSBList.Items[board].HidCtrl)) and (NOT AUSBList.Items[board].HidCtrl.IsPluggedIn)) then
      begin
        if Assigned(FOnUSBDeviceChange) then
        begin
          FOnUSBDeviceChange(Self,-1*board);
        end;
        AUSBList.Items[board].HidCtrl.FlushQueue;
        HidCtl.CheckIn(AUSBList.Items[board].HidCtrl);
        break;
      end;
    end;
    if HidCtl.NumCheckedOutDevices=0 then FEmulation:=True;
  end;
end;

procedure TUSB.DeviceArrival(HidDev: TJvHidDevice);
var
  newboard:integer;
  NewUSBController : TUSBController;
begin

  AddInfo('Device arrival. VID: '+InttoStr(HidDev.Attributes.VendorID)+'. PID: '+InttoStr(HidDev.Attributes.ProductID)+'.');

  if ( (HidDev.Attributes.VendorID = Vendor) AND
       (HidDev.Attributes.ProductID = Product) ) then
  begin

    if HidDev.CheckOut then
    begin

      FEmulation:=False;

      AddInfo('I1: '+HidDev.DeviceStrings[1]);
      AddInfo('I2: '+HidDev.DeviceStrings[2]);
      AddInfo('I3: '+HidDev.DeviceStrings[3]);
      AddInfo('I4: '+HidDev.DeviceStrings[4]);

      NewUSBController := TUSBController.Create(HidDev);

      Sleep(200);
      //Setlength(NewUSBController.LocalData.Data,HidDev.Caps.InputReportByteLength);

      with NewUSBController do
      begin
        Serial:='';
        FaultCounter:=0;
      end;

      Sleep(200);

      with NewUSBController do
      begin
        if HidCtrl.DeviceStrings[4]<>HidCtrl.DeviceStrings[1] then
        begin
          Serial:=HidCtrl.DeviceStrings[4];
        end;
      end;
      if NewUSBController.Serial='' then ReadSerial(NewUSBController);

      if NewUSBController.Serial='' then
      begin
        AddInfo('Severe error while receiving serial number of controller !!!!');
        exit;
      end;

      newboard:=CheckAddressNewer(NewUSBController);

      AddInfo('S/N of board '+InttoStr(newboard)+': '+NewUSBController.Serial);

      while AUSBList.Count<(newboard+1) do
      begin
        AUSBList.Add(TUSBController.Create(nil));
      end;

      AUSBList.Items[newboard]:=NewUSBController;

      if Assigned(FOnUSBDeviceChange) then
      begin
        FOnUSBDeviceChange(Self,newboard);
      end;
    end;
  end;
end;

procedure TUSB.DeviceChange(Sender:TObject);
var
  board:integer;
  i:integer;
  HidDev:TJvHidDevice;
begin
  AddInfo('Devices change !!');
  for i:=0 to HidCtl.HidDevices.Count-1 do
  begin
    HidDev:=HidCtl.HidDevices[i];
    AddInfo('HID-device#'+InttoStr(i)+'. VID: '+InttoStr(HidDev.Attributes.VendorID)+'. PID: '+InttoStr(HidDev.Attributes.ProductID)+'.');
    if ( (HidDev.Attributes.VendorID = Vendor) AND
       (HidDev.Attributes.ProductID = Product) ) then
    begin
      if HidDev.IsPluggedIn AND NOT HidDev.IsCheckedOut then
      begin
        AddInfo('New device that has not been checked out.');
        DeviceArrival(HidDev);
      end;
      if NOT HidDev.IsPluggedIn AND HidDev.IsCheckedOut then
      begin
        AddInfo('Checkedout device that has been unplugged.');
        DeviceRemoval(HidDev);
      end;
    end;
  end;
end;

function TUSB.CheckAddressNewer(Ctrl: TUSBController):integer;
var
  x,y: integer;
  newboardnumber:word;
  found:boolean;

  RegValueNames: TStringList;

  dataline:string;
  error:boolean;
  ErrorCounter:word;

  Ini: TIniFile;
begin

  result:=0;

  error:=False;

  if (NOT error) then
  begin
    if (Ctrl.Serial='0-0-0-0-0-0')
       OR
       (Ctrl.Serial='0000-0000-0000-0000-0000-0000')
       OR
       (Ctrl.Serial='65535-65535-65535-65535-65535-65535')
       OR
       (Ctrl.Serial='FFFF-FFFF-FFFF-FFFF-FFFF-FFFF')
       OR
       (RightStr(Ctrl.Serial,4)='FFFF')
       then
    begin
      ErrorCounter:=1;

      repeat

        with Ctrl do
        begin
          FillChar(LocalData, SizeOf(LocalData), 0);

          LocalData.Data[0] := byte(CMD_set_serial);
          LocalData.Data[1] := Random($FF);
          LocalData.Data[2] := Random($FF);
          LocalData.Data[3] := Random($FF);
          LocalData.Data[4] := Random($FF);
          LocalData.Data[5] := Random($FF);
          LocalData.Data[6] := Random($FF);
          LocalData.Data[7] := Random($FF);
          LocalData.Data[8] := Random($FF);
          LocalData.Data[9] := Random($FF);
          LocalData.Data[10] := Random($FF);
          LocalData.Data[11] := Random($FF);
          LocalData.Data[12] := Random($FF);
        end;
        error:=HidReadWrite(Ctrl,True);

        if (NOT error) then with Ctrl.LocalData do
        begin
          if (data[0]=byte(CMD_set_serial)) then
          begin
            Ctrl.Serial:=
              InttoHex(WORD(data[1]+data[2]*256),4)+'-'+
              InttoHex(WORD(data[3]+data[4]*256),4)+'-'+
              InttoHex(WORD(data[5]+data[6]*256),4)+'-'+
              InttoHex(WORD(data[7]+data[8]*256),4)+'-'+
              InttoHex(WORD(data[9]+data[10]*256),4)+'-'+
              InttoHex(WORD(data[11]+data[12]*256),4);
          end
          else
          begin
            error:=True;
          end;
        end;
        if ( (error) AND (ErrorCounter<MaxErrors) ) then sleep(25);
        Inc(ErrorCounter);
      until ((NOT error) OR (ErrorCounter>MaxErrors) );
      if error then AddErrors('Controller set serial number error');
    end;
  end;

  if (NOT error)  then
  begin
    found:=false;

    newboardnumber:=0;

    Ini := TIniFile.Create(FIniFileFullPath);

    RegValueNames:=TStringList.Create;
    try
      ini.ReadSection('USBLocations',RegValueNames);
      if RegValueNames.Count>0 then
      begin
        for x:=1 to RegValueNames.Count do
        begin
          If Pos('Controller',RegValueNames.Strings[x-1])>-1 then
          begin
            y:=StrToIntDef(RightStr(RegValueNames.Strings[x-1],2),0);
            dataline:=ini.ReadString('USBLocations',RegValueNames.Strings[x-1],'');
            if (dataline=Ctrl.Serial) AND (y>0) then
            begin
              found:=true;
              newboardnumber:=y;
              break;
            end;
          end;
        end;
      end;
      if (NOT found) then
      begin
        y:=1;
        while ini.ValueExists('USBLocations','Controller '+InttoStr(y)) do Inc(y);
        ini.WriteString('USBLocations','Controller '+InttoStr(y),Ctrl.Serial);
        newboardnumber:=y;
      end;
    finally
      RegValueNames.Free;
      Ini.UpdateFile;
      Ini.Free;
    end;

    result:=newboardnumber;
  end;

end;

procedure TUSB.HandleCRCError(HidCtrl: TJvHidDevice);
begin
  begin
    //if Assigned(HidCtrl) then HidCtrl.FlushQueue;
    //if Assigned(HidCtrl) then HidCtrl.CloseFileEx(omhRead);
    //if Assigned(HidCtrl) then HidCtrl.CloseFileEx(omhWrite);
  end;
end;

function TUSB.CheckParameters(board:word):boolean;
begin
  result:=true;
  if  FEmulation then exit;
  result:=NOT ( (board<AUSBList.Count) AND (Assigned(AUSBList.Items[board].HidCtrl)) );
end;

function TUSB.GetErrors:String;
begin
  if FErrors.Count>0 then
  begin
    result:=FErrors.Text;
    FErrors.Clear;
  end else result:='';
end;

procedure TUSB.AddInfo(data:string);
begin
  if Length(data)>0 then
  begin
    while FInfo.Count>1000 do FInfo.Delete(0);
    FInfo.Append(data);
  end;
end;

function TUSB.GetInfo:String;
begin
  if FInfo.Count>0 then
  begin
    result:=FInfo.Text;
    FInfo.Clear;
  end else result:='';
end;

procedure TUSB.AddErrors(data:string);
begin
  if length(data)>0 then
  begin
   while FErrors.Count>1000 do FErrors.Delete(0);
   FErrors.Append(DateTimeToStr(Now)+': '+data);
  end;
end;

function TUSB.ReadSerial(Ctrl: TUSBController):string;
var
  error:boolean;
  ErrorCounter:word;
begin
  Result:='';

  ErrorCounter:=1;

  repeat
    FillChar(Ctrl.LocalData, SizeOf(Ctrl.LocalData), 0);
    Ctrl.LocalData.Data[0] := Integer(CMD_get_serial);

    error:=HidReadWrite(Ctrl,False);

    if (NOT error) then with Ctrl.LocalData do
    begin
      if ( data[0]=byte(CMD_get_serial) ) then
      begin
        result:=
          InttoHex(WORD(data[1]+data[2]*256),4)+'-'+
          InttoHex(WORD(data[3]+data[4]*256),4)+'-'+
          InttoHex(WORD(data[5]+data[6]*256),4)+'-'+
          InttoHex(WORD(data[7]+data[8]*256),4)+'-'+
          InttoHex(WORD(data[9]+data[10]*256),4)+'-'+
          InttoHex(WORD(data[11]+data[12]*256),4);
        Ctrl.Serial:=Result;
      end else error:=True;
    end;

    if ( (error) AND (ErrorCounter<MaxErrors) ) then sleep(25);
    Inc(ErrorCounter);

  until ((NOT error) OR (ErrorCounter>MaxErrors) );
  if error then AddErrors('Controller read serial number error');
end;

function TUSB.FGetSerial(board:word):string;
begin
  result:='';
  if FEmulation then exit;
  if AUSBList.Count=0 then exit;
  if board>AUSBList.Count then exit;
  result:=AUSBList.Items[board].Serial;
end;

end.
