///-------------------------------------------------------------------------------
/// Title      : GS.Threads.Pool
/// Short Desc : Introduce simple and efficient pool capability.
/// Source     : https://github.com/VincentGsell
/// Aim        : - Simple way to submit "task" and execute it ASAP accordingly to
///                a defined resident managed thread pool.
///-------------------------------------------------------------------------------
/// Thread minimalist pool implementation.
/// 1) Create a TStackThreadPool instance. This instance should be resident. It'll wait for TStackTask object.
/// 2) Implement your "task" on a inheritated TStackTask
/// 3) Call YourThreadPool instance as is : YourThreaDPool.Submit(YourTask);
/// 4) Following yourTaks option, YourTak will be delivered by an event.
unit GS.Threads.Pool;

{$IFDEF FPC}
{$mode delphi}
{$ENDIF}

interface

Uses
{$IFDEF FPC}
  Classes,
  SysUtils,
  Generics.Collections,
  SyncObjs,
{$ELSE}
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  System.SyncObjs,
  System.Threading,
{$ENDIF}
  GS.Threads;

Const
  CST_THREAD_POOL_WAIT_DURATION     = 250;  //Millisec.
  CST_DEFAULT_POOL_CAPACITY         = 4;    //thread number by default.
  CST_MAXTHREADCONTINIOUSIDLINGTIME = 1000; //In case of dynamic thread pool, if a thread is idling continously during this time, it will terminate.

Type

  //Make choice...
  //...Overide this to make your task (this one is good for task "Without loop" inside...
  TStackTask = Class
    Procedure Execute; Virtual; abstract;
  end;

  //...or if you plan to use tasks for long process (which have loop or which is long), use this one instead,
  //and test Terminated value. (as you do as a thread).
  TStackTaskProc = Class(TStackTask)
  protected
    Fterminated : boolean;
  public
    Constructor Create; Virtual;
    procedure Terminate;
    Property Terminated : Boolean read FTerminated;
  end;


  TThreadTask = class; //real TThread descendant (Resident "reused" thread)
  TStackThreadPool = class; //Pool object.

  TThreadTaskStatus = (WaitForStart, Idle, Processing, Terminating);
  TThreadTask = Class(TThread)
  private
    //for event (synchro or not)
    FEventTask : TStackTask;
    FTaskTick : UInt64;
    Procedure InternalDoStackTaskEventStart;
    Procedure InternalDoStackTaskEventFinished;
  protected
    FStatus : TProtectedValue<TThreadTaskStatus>;
    FThreadIndex : UInt32;
    FWorkNow : TEvent;
    FThreadPool : TStackThreadPool; //Pointer.
    function GetStatus: TThreadTaskStatus;
  Public
    Constructor Create(aThreadPool : TStackThreadPool); Reintroduce;
    Destructor Destroy; Override;
    Procedure Execute; Override;
    Procedure Run; Virtual;
    Property Status : TThreadTaskStatus read GetStatus;
  End;

  TStackTaskEvent = Procedure(Const aThreadIndex : UInt32; aIStackTask : TStackTask; TaskProcessTimeValue : UInt64) of Object;
  ///Named TStackThreadPool mainly because of Delphi's TThreadPool.
  ///
  /// TStackThreadPool : a Thread pool which :
  ///  - Keep a list of task submited.
  ///  - Can free the task after processing, or not (Property FreeTaskOnceProcessed (Default : True))
  ///  - Summon <PoolCapacity> number of thread, no more, no less.
  ///  - Once you have called "Warm", or once your first task submited, all ressource are up and ready.
  ///  - Once ressource up and ready, it is very efficient to take task and process (because threads are up and ready)
  ///  - In delphi, it replace efficiently TTask, it is as efficient as TTask, but there are Metrics and ressource manageged.
  TStackThreadPool = class
  private
  protected
    FFreeTaskOnceProcessed: boolean;
    FCurrentStackProtector : TCriticalSection;
    FCurrentStack : TList<TStackTask>;
    FSynchoEvent : TProtectedBoolean;
    FOnStackFinished: TStackTaskEvent;
    FPoolCapacity: Uint32;
    FOnStackStart: TStackTaskEvent;
    function GetSynchronized: Boolean;
    procedure SetSynchronized(const Value: Boolean);

    function GetPoolCapacity: Uint32; virtual;
    function GetStackTaskCount: Uint32;
    function GetAllThreadAreIdling: Boolean;
    function InternalThreadIdling(alist : TList<TThreadTask>) : Boolean;
    function ThreadIdling : Boolean; //Pool protected.

    //On first submit, ressource are allocated. If there are no submit, no thread exists.
    Procedure check; virtual;
    procedure clean; virtual;
    procedure clean_(lt : TList<TThreadTask>); virtual; //Unprotected !
  public
    Pool : TProtectedObject<TList<TThreadTask>>;

    /// aInitialPoolCapacity : Minimal thread count allotated at start.
    ///  Warm : By defautl, thread allocation is done on first task submission.
    ///         If True, allocation are done directly, and thus, ThreadPool is ready to serve.
    Constructor Create(const aInitialPoolCapacity : UInt32 = CST_DEFAULT_POOL_CAPACITY; const Warm : Boolean = False); Reintroduce;
    Destructor Destroy; Override;
    procedure Terminate; //Terminate send terminate at all thread and TStackTask (if they are TStackTaskProc)

    //Procedure GetPoolState : UnicodeString;
    Procedure Submit(aIStackTask : TStackTask); Virtual;

    Property OnTaskStart : TStackTaskEvent read FOnStackStart Write FOnStackStart;
    Property OnTaskFinished : TStackTaskEvent read FOnStackFinished Write FOnStackFinished;

    Property PoolCapacity : Uint32 read GetPoolCapacity;
    Property Synchronized : Boolean read GetSynchronized Write SetSynchronized;
    Property StackTaskCount : Uint32 read GetStackTaskCount;
    Property FreeTaskOnceProcessed : boolean read FFreeTaskOnceProcessed Write FFreeTaskOnceProcessed;

    Property Idle : Boolean read GetAllThreadAreIdling;
  end;

  //Idem than TStackThreadPool, but dynamic thread capacity and management.
  TStackDynamicThreadPool = Class(TStackThreadPool)
  private
    FMaxThreadCount: TProtectedNativeUInt;
    FMaxThreadContiniousIdlingTime: TProtectedNativeUInt;
  protected
    procedure Check; Override;
    function GetPoolCapacity: Uint32; Override;
  public
    Constructor Create(const Warm : Boolean = False); Reintroduce;
    destructor Destroy; Override;

    Property MaxPoolCapacity : TProtectedNativeUInt read FMaxThreadCount write FMaxThreadCount;
    property MaxThreadContiniousIdlingTime : TProtectedNativeUInt read FMaxThreadContiniousIdlingTime Write FMaxThreadContiniousIdlingTime;
  End;


implementation

{ TStackThreadPool }

procedure TStackThreadPool.Check;
var i : Integer;
    lt : TList<TThreadTask>;
begin
  lt := Pool.Lock;
  try
    if lt.Count=0 then
    begin
      if FPoolCapacity < 1 then
        FPoolCapacity := 1;
      for I := 1 to FPoolCapacity do
      begin
        lt.Add(TThreadTask.Create(Self));
        lt[lt.Count-1].Run;
      end;
    end;
    for I := 0 to lt.Count-1 do
    begin
      if lt[i].Started then
        lt[i].Run; //Pulse
    end;
  finally
    Pool.Unlock;
  end;
end;

procedure TStackThreadPool.clean;
var lt : TList<TThreadTask>;
begin
  lt := Pool.Lock;
  try
    clean_(lt);
  finally
    Pool.Unlock;
  end;
end;

procedure TStackThreadPool.clean_(lt: TList<TThreadTask>);
var i : integer;
begin
  for i := lt.Count-1 downto 0 do
  begin
    if lt[i].Terminated then
    begin
      lt[i].WaitFor;
      lt[i].Free;
      lt.Delete(i);
    end;
  end;
end;

constructor TStackThreadPool.Create(const aInitialPoolCapacity: UInt32; const Warm : Boolean);
var v : TProtectedObject<TList>;
begin
  FSynchoEvent := TProtectedBoolean.Create(True);
  FCurrentStackProtector := TCriticalSection.Create;
  FCurrentStack := TList<TStackTask>.Create;

  Pool := TProtectedObject<TList<TThreadTask>>.Create(TList<TThreadTask>.Create);

  FPoolCapacity := aInitialPoolCapacity;
  FFreeTaskOnceProcessed := True;

  if Warm then
    check;
end;

destructor TStackThreadPool.Destroy;
var i : integer;
    lt : TList<TThreadTask>;
begin
  FOnStackFinished := Nil;
  FOnStackStart := Nil;

  lt := Pool.Lock;
  try
    for I := 0 to lt.Count-1 do
    begin
      if lt[i].Started then
      begin
        lt[i].Terminate;
        lt[i].Run;
        lt[i].WaitFor;
      end;
      lt[i].Free;
    end;
  finally
    pool.Unlock;
  end;
  FreeAndNil(Pool);
  FreeAndNil(FSynchoEvent);

  //Freeing task not yet executed.
  FCurrentStackProtector.Acquire;
  try
    for I := 0 to FCurrentStack.Count-1 do
    begin
      TObject(FCurrentStack[i]).Free;
    end;
  finally
    FCurrentStackProtector.Release;
  end;
  FreeAndNil(FCurrentStack);
  FreeAndNil(FCurrentStackProtector);
end;

function TStackThreadPool.GetAllThreadAreIdling: Boolean;
var i : integer;
    lt : TList<TThreadTask>;
begin
  Result := ThreadIdling;
end;

function TStackThreadPool.GetPoolCapacity: Uint32;
begin
  result := FPoolCapacity;
end;

function TStackThreadPool.GetStackTaskCount: Uint32;
begin
  FCurrentStackProtector.Acquire;
  try
    result := FCurrentStack.Count;
  finally
    FCurrentStackProtector.Release;
  end;
end;

function TStackThreadPool.GetSynchronized: Boolean;
begin
  result := FSynchoEvent.Value;
end;

function TStackThreadPool.InternalThreadIdling(
  alist: TList<TThreadTask>): Boolean;
var i : integer;
begin
  Result := True;
  for i := 0 to aList.Count-1 do
  begin
    If Not ((aList[i].Status = TThreadTaskStatus.Idle) Or (aList[i].Terminated)) then
    begin
      Result := False;
      Break;
    end;
  end;
end;

procedure TStackThreadPool.SetSynchronized(const Value: Boolean);
begin
  FSynchoEvent.Value := Value;
end;


procedure TStackThreadPool.Submit(aIStackTask: TStackTask);
begin
  FCurrentStackProtector.Acquire;
  try
    FCurrentStack.Add(aIStackTask);
  finally
    FCurrentStackProtector.Release;
  end;
  check;
end;

procedure TStackThreadPool.Terminate;
var lt : TList<TThreadTask>;
    i : integer;
begin
  lt := Pool.Lock;
  try
    for i := 0 to lt.Count-1 do
      lt[i].Terminate;
  finally
    Pool.Unlock;
  end;
end;

function TStackThreadPool.ThreadIdling: Boolean;
var lt : TList<TThreadTask>;
    i : integer;
begin
//  FCurrentStackProtector.Acquire;
//  try
//    Result := FCurrentStack.Count = 0;
//  finally
//    FCurrentStackProtector.Release;
//  end;

  lt := Pool.Lock;
  try
    result := InternalThreadIdling(lt);
    //result := Result And InternalThreadIdling(lt);
  finally
    Pool.Unlock;
  end;
end;

{ TThreadTask }

constructor TThreadTask.Create(aThreadPool: TStackThreadPool);
var lt : TList<TThreadTask>;
begin
  Inherited Create(true);
  Assert(Assigned(aThreadPool));
  FStatus := TProtectedValue<TThreadTaskStatus>.Create(WaitForStart);
  FreeOnTerminate := False;
  FThreadPool := aThreadPool;
  FWorkNow := TEvent.Create(nil,false,false,emptystr);
  lt := aThreadPool.Pool.Lock;
  try
    FThreadIndex := lt.Count;
  finally
    aThreadPool.Pool.Unlock;
  end;
  {$IFDEF DEBUG}
  NameThreadForDebugging(Format('%s - num. %d',[ClassName,FThreadIndex]));
  {$ENDIF}
end;

destructor TThreadTask.Destroy;
begin
  if Assigned(FEventTask) then
  begin
    if FEventTask is TStackTaskProc then
    begin
       TStackTaskProc(FEventTask).Terminate;
    end;

    if FThreadPool.FreeTaskOnceProcessed  then
    begin
      FreeAndNil(FEventTask);
    end;
  end;
  Terminate;
  WaitFor;
  FreeAndNil(FStatus);
  FreeAndNil(FWorkNow);
  inherited;
end;

procedure TThreadTask.Execute;
var FInternalTask : TStackTask;
    FTiming : TThread.TSystemTimes;
    FIdleTime : Uint64;
    FCurrentStackCount : Uint32;

  Procedure DoEventStart;
  begin
    if FThreadPool.Synchronized then
    begin
      if assigned(FThreadPool.OnTaskStart) then
        Synchronize(InternalDoStackTaskEventStart);
    end
    else
    begin
      raise Exception.Create('to do : In this thread or in another one ? Bus ?');
    end;
  end;

  Procedure DoEventFinished;
  begin
    if FThreadPool.Synchronized then
    begin
      if assigned(FThreadPool.OnTaskFinished) then
        Synchronize(InternalDoStackTaskEventFinished);
    end
    else
    begin
      raise Exception.Create('to do : In this thread or in another one ? Bus ?');
    end;
  end;

  Procedure ExecuteTask;
  begin
    try
      FStatus.Value := Processing;
      TThread.GetSystemTimes(FTiming);
      FTaskTick := FTiming.UserTime;
      FEventTask := FInternalTask;
      DoEventStart;
      if Terminated then Exit;
      FInternalTask.Execute;
      if Terminated then Exit;
      TThread.GetSystemTimes(FTiming);
      FTaskTick := FTiming.UserTime - FTaskTick;
      DoEventFinished;
      if Terminated then Exit;
    Except
      //Event Error
    end;

    try
      if FThreadPool.FreeTaskOnceProcessed  then
      begin
        FreeAndNil(FEventTask);
      end;
    Except
      //Event free error.
    end;
  end;

begin

  while Not Terminated do
  begin
    case FWorkNow.WaitFor(CST_THREAD_POOL_WAIT_DURATION) of
    wrSignaled :
    begin
      if Terminated then Exit;
      //Ask if a task is available to run
      Repeat
        FInternalTask := nil;
        FThreadPool.FCurrentStackProtector.Acquire;
        try
          FCurrentStackCount := FThreadPool.FCurrentStack.Count;
          if FCurrentStackCount>0 then
          begin
            FInternalTask := FThreadPool.FCurrentStack[0];
            FThreadPool.FCurrentStack.Delete(0);
            FIdleTime := 0;
          end;
        finally
          FThreadPool.FCurrentStackProtector.Release;
        end;
        if Terminated then Exit;

        if Assigned(FInternalTask) then
        begin
          ExecuteTask;
        end;
      Until FInternalTask = nil;
      FStatus.Value := Idle;
    end;
    wrTimeout :
    begin
      if Terminated then Exit;

      if FThreadPool is TStackDynamicThreadPool then
      begin

        FThreadPool.FCurrentStackProtector.Acquire;
        try
          FCurrentStackCount := FThreadPool.FCurrentStack.Count;
        finally
          FThreadPool.FCurrentStackProtector.Release;
        end;

        if FCurrentStackCount=0 then
        begin
          FThreadPool.clean;
          FIdleTime := FIdleTime + CST_THREAD_POOL_WAIT_DURATION;
          if FIdleTime > TStackDynamicThreadPool(FthreadPool).MaxThreadContiniousIdlingTime.Value then
          begin
            if  FThreadPool.PoolCapacity>1 then //I'm really not the last one ?
              Terminate; //No : suicide. :/
          end
          else
          begin
            FWorkNow.SetEvent;  //Check stack again.
          end;

        end;
      end;

    end;
    wrAbandoned, wrError :
    begin
      if Terminated then Exit;
    end;
    end;
  end;
  FStatus.Value := Terminating;
  if Assigned(FEventTask) then
  begin
    if FThreadPool.FreeTaskOnceProcessed  then
    begin
      FreeAndNil(FEventTask);
    end;
  end;
end;

function TThreadTask.GetStatus: TThreadTaskStatus;
begin
  result := FStatus.Value;
end;

procedure TThreadTask.InternalDoStackTaskEventFinished;
begin
  FThreadPool.OnTaskFinished(FThreadIndex, FEventTask, FTaskTick);
end;

procedure TThreadTask.InternalDoStackTaskEventStart;
begin
FThreadPool.OnTaskStart(FThreadIndex, FEventTask, 0);
end;

procedure TThreadTask.Run;
begin
  if Not(Terminated) and Not(Started) then
    Start;
  if Not(Terminated) then
    FWorkNow.SetEvent;
end;

{ TStackTaskProc }

constructor TStackTaskProc.Create;
begin
  Inherited;
  FTerminated := False;
end;

procedure TStackTaskProc.Terminate;
begin
  Fterminated := True;
end;

{ TStackDynaminThreadPool }

procedure TStackDynamicThreadPool.check;
var i : Integer;
    lt : TList<TThreadTask>;
    lNeedNewThread : Boolean;
begin
  lt := Pool.Lock;
  try
    Clean_(lt);
    if lt.Count=0 then
    begin
      //We need a least one thread.
      lt.Add(TThreadTask.Create(Self));
      lt[0].Run;
    end
    else
    begin
      //Delete Terminated thread.
      if Not(InternalThreadIdling(lt)) then  //Is all thread are occupied ?
      begin
        //Yes : in this case : Create new thread if limit not reached.
        // if MaxThreadCount is reach, TStackTask will put in a stack. Once liberate from its internal task, a thread will take it in charge.
        //(n.b. : Automatic ressource recovery are done in TTaskThread).
        if lt.Count<MaxPoolCapacity.Value then
        begin
          lt.Add(TThreadTask.Create(Self)); //this new thread will get task.
          lt[lt.Count-1].Run;
        end
        else
        begin
          // todo/Idea : An Overload property, which indicate if there are too many task ?
        end;
      end
      else
      begin
        //Pulse : Look for the first in idling and push it.
        for I :=0 to lt.Count-1 do
        begin
          if lt[i].Status = TThreadTaskStatus.Idle then
          begin
            lt[i].Run;
            break;
          end;
        end;
      end;
    end;
  finally
    Pool.Unlock;
  end;
end;

constructor TStackDynamicThreadPool.Create(const Warm: Boolean);
begin
  Inherited Create(1);
  FMaxThreadCount := TProtectedNativeUInt.Create(CPUCount);
  FMaxThreadContiniousIdlingTime := TProtectedNativeUInt.Create(CST_MAXTHREADCONTINIOUSIDLINGTIME);
  if Warm then
    check;
end;

destructor TStackDynamicThreadPool.Destroy;
begin
  FreeAndNil(FMaxThreadCount);
  FreeAndNil(FMaxThreadContiniousIdlingTime);
  inherited;
end;


function TStackDynamicThreadPool.GetPoolCapacity: Uint32;
var lt : TList<TThreadTask>;
    i : integer;
begin
  lt := Pool.Lock;
  try
    Result := lt.Count;
  finally
    Pool.Unlock;
  end;
end;

end.
