{*******************************************************************************
  uDataSetGPUFilter.pas v0.1

  Headless OpenGL 4.3 Compute Shader filter for standard Delphi TDataSet
  components (TFDMemTable, TFDQuery, TClientDataSet, etc.).
  Performs parallel range, category, and 16-char substring searches across
  millions of rows in VRAM within a few milliseconds without external DLLs.

  Author:  Lara Miriam Tamy Reschke / LaMitaOne
*******************************************************************************}
unit uDataSetGPUFilter;

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.OpenGL, Winapi.OpenGLext,
  System.SysUtils, System.Classes, System.Generics.Collections, Data.DB;

type
  // Strictly 32 bytes (2x uvec4 in GLSL std430 layout)
  TGPUDataRow = packed record
    RecNo: Int32;                         // 4 bytes: 1-based row index in DataSet
    Category: Int32;                      // 4 bytes: Category ID
    Amount: Single;                       // 4 bytes: Numeric value / amount
    Reserved: Int32;                      // 4 bytes: Padding to 16-byte boundary
    TextPack0: UInt32;                    // 4 bytes: Uppercase ASCII chars 1..4
    TextPack1: UInt32;                    // 4 bytes: Uppercase ASCII chars 5..8
    TextPack2: UInt32;                    // 4 bytes: Uppercase ASCII chars 9..12
    TextPack3: UInt32;                    // 4 bytes: Uppercase ASCII chars 13..16
  end;

  PGPUDataRow = ^TGPUDataRow;

  TDataSetGPUFilter = class
  private
    FDummyWnd: HWND;
    FDC: HDC;
    FRC: HGLRC;
    FInitialized: Boolean;

    FProgram: GLuint;
    FInputSSBO: GLuint;
    FOutputSSBO: GLuint;
    FCounterSSBO: GLuint;

    FRowCount: Integer;
    FMaxResults: Integer;

    FLocRowCount: GLint;
    FLocCategory: GLint;
    FLocMinAmount: GLint;
    FLocSearchLen: GLint;
    FLocSearchPack: GLint;

    procedure InitHeadlessGL;
    procedure CleanupGL;
    function CompileComputeShader(const ASource: string): GLuint;
    class procedure PackText16(const AText: string; out P0, P1, P2, P3: UInt32); static;
  public
    constructor Create(AMaxResults: Integer = 50000);
    destructor Destroy; override;

    // Reads all records from a TDataSet once and uploads them into GPU VRAM
    procedure Attach(ADataSet: TDataSet; const ACatField, AAmountField, ATextField: string);

    // Filters all uploaded rows in parallel on the GPU and returns matching row indices
    function Filter(const ASearchText: string; ACategory: Integer; AMinAmount: Single; out ATotalMatches: Integer): TArray<Integer>;

    property IsReady: Boolean read FInitialized;
    property RowCount: Integer read FRowCount;
    property MaxResults: Integer read FMaxResults;
  end;

implementation

const
  WGL_CONTEXT_MAJOR_VERSION_ARB = $2091;
  WGL_CONTEXT_MINOR_VERSION_ARB = $2092;
  WGL_CONTEXT_PROFILE_MASK_ARB = $9126;
  WGL_CONTEXT_CORE_PROFILE_BIT_ARB = $00000001;
  GL_COMPUTE_SHADER = $91B9;
  GL_SHADER_STORAGE_BUFFER = $90D2;
  GL_SHADER_STORAGE_BARRIER_BIT = $00002000;
  GL_DYNAMIC_COPY = $88EA;
  COMPUTE_SHADER_SRC = '#version 430 core'#10 + 'layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;'#10 + ''#10 + 'struct DataRow {'#10 + '    int recNo;'#10 + '    int category;'#10 + '    float amount;'#10 + '    int reserved;'#10 + '    uvec4 textPack;'#10 + '};'#10 + ''#10 + 'layout(std430, binding = 0) readonly buffer InputBuffer {'#10 + '    DataRow rows[];'#10 + '};'#10 + ''#10 + 'layout(std430, binding = 1) writeonly buffer OutputBuffer {'#10 + '    int hitRecNos[];'#10 + '};'#10 +
    ''#10 + 'layout(std430, binding = 2) coherent buffer CounterBuffer {'#10 + '    uint matchCount;'#10 + '    uint maxOut;'#10 + '};'#10 + ''#10 + 'uniform int uRowCount;'#10 + 'uniform int uTargetCategory;'#10 + 'uniform float uMinAmount;'#10 + 'uniform int uSearchLen;'#10 + 'uniform uvec4 uSearchPack;'#10 + ''#10 + 'uint getChar(uvec4 pack, int idx) {'#10 + '    uint word = pack[idx >> 2];'#10 + '    uint shift = uint((idx & 3) * 8);'#10 + '    return (word >> shift) & 0xFFu;'#10 + '}'#10 + ''#10 +
    'bool matchText(uvec4 rowPack) {'#10 + '    if (uSearchLen <= 0) return true;'#10 + '    if (uSearchLen > 16) return false;'#10 + '    int maxStart = 16 - uSearchLen;'#10 + '    for (int start = 0; start <= maxStart; ++start) {'#10 + '        bool ok = true;'#10 + '        for (int j = 0; j < uSearchLen; ++j) {'#10 + '            uint rc = getChar(rowPack, start + j);'#10 + '            if (rc == 0u || rc != getChar(uSearchPack, j)) {'#10 + '                ok = false;'#10 + '                break;'#10
    + '            }'#10 + '        }'#10 + '        if (ok) return true;'#10 + '    }'#10 + '    return false;'#10 + '}'#10 + ''#10 + 'void main() {'#10 + '    uint idx = gl_GlobalInvocationID.x;'#10 + '    if (idx >= uint(uRowCount)) return;'#10 + ''#10 + '    DataRow r = rows[idx];'#10 + '    if (uTargetCategory > 0 && r.category != uTargetCategory) return;'#10 + '    if (r.amount < uMinAmount) return;'#10 + '    if (!matchText(r.textPack)) return;'#10 + ''#10 + '    uint slot = atomicAdd(matchCount, 1u);'#10 + '    if (slot < maxOut) {'#10 + '        hitRecNos[slot] = r.recNo;'#10 + '    }'#10 + '}';

type
  TwglCreateContextAttribsARB = function(hDC: HDC; hShareContext: HGLRC; const attribList: PInteger): HGLRC; stdcall;

{ TDataSetGPUFilter }

constructor TDataSetGPUFilter.Create(AMaxResults: Integer);
begin
  inherited Create;
  FMaxResults := AMaxResults;
  InitHeadlessGL;
end;

destructor TDataSetGPUFilter.Destroy;
begin
  CleanupGL;
  inherited;
end;

procedure TDataSetGPUFilter.InitHeadlessGL;
const
  CTX_ATTRIBS: array[0..6] of Integer = (WGL_CONTEXT_MAJOR_VERSION_ARB, 4, WGL_CONTEXT_MINOR_VERSION_ARB, 3, WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_CORE_PROFILE_BIT_ARB, 0);
var
  PFD: TPixelFormatDescriptor;
  PF: Integer;
  TempRC: HGLRC;
  wglCreateContextAttribsARB: TwglCreateContextAttribsARB;
  Shader: GLuint;
begin
  // Create an invisible 1x1 dummy window to host a headless OpenGL context
  FDummyWnd := CreateWindowEx(0, 'STATIC', 'YutaniGPGPU', WS_POPUP, 0, 0, 1, 1, 0, 0, HInstance, nil);
  if FDummyWnd = 0 then
    raise Exception.Create('Failed to create headless dummy window.');

  FDC := GetDC(FDummyWnd);
  FillChar(PFD, SizeOf(PFD), 0);
  PFD.nSize := SizeOf(PFD);
  PFD.nVersion := 1;
  PFD.dwFlags := PFD_DRAW_TO_WINDOW or PFD_SUPPORT_OPENGL;
  PFD.iPixelType := PFD_TYPE_RGBA;
  PFD.cColorBits := 32;

  PF := ChoosePixelFormat(FDC, @PFD);
  SetPixelFormat(FDC, PF, @PFD);

  TempRC := wglCreateContext(FDC);
  wglMakeCurrent(FDC, TempRC);

  // Request an OpenGL 4.3 Core Profile context for Compute Shader support
  wglCreateContextAttribsARB := TwglCreateContextAttribsARB(wglGetProcAddress('wglCreateContextAttribsARB'));

  if Assigned(wglCreateContextAttribsARB) then
  begin
    FRC := wglCreateContextAttribsARB(FDC, 0, @CTX_ATTRIBS);
    if FRC <> 0 then
    begin
      wglMakeCurrent(0, 0);
      wglDeleteContext(TempRC);
      wglMakeCurrent(FDC, FRC);
    end
    else
      FRC := TempRC;
  end
  else
    FRC := TempRC;

  InitOpenGLext;

  if not Assigned(glDispatchCompute) or not Assigned(glBindBufferBase) then
    raise Exception.Create('OpenGL 4.3 Compute Shaders are not supported by this GPU/driver.');

  Shader := CompileComputeShader(COMPUTE_SHADER_SRC);
  FProgram := glCreateProgram();
  glAttachShader(FProgram, Shader);
  glLinkProgram(FProgram);
  glDeleteShader(Shader);

  FLocRowCount := glGetUniformLocation(FProgram, 'uRowCount');
  FLocCategory := glGetUniformLocation(FProgram, 'uTargetCategory');
  FLocMinAmount := glGetUniformLocation(FProgram, 'uMinAmount');
  FLocSearchLen := glGetUniformLocation(FProgram, 'uSearchLen');
  FLocSearchPack := glGetUniformLocation(FProgram, 'uSearchPack');

  glGenBuffers(1, @FInputSSBO);
  glGenBuffers(1, @FOutputSSBO);
  glGenBuffers(1, @FCounterSSBO);

  // Pre-allocate output index buffer and atomic counter buffer
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FOutputSSBO);
  glBufferData(GL_SHADER_STORAGE_BUFFER, FMaxResults * SizeOf(Int32), nil, GL_DYNAMIC_COPY);

  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FCounterSSBO);
  glBufferData(GL_SHADER_STORAGE_BUFFER, 2 * SizeOf(UInt32), nil, GL_DYNAMIC_COPY);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);

  FInitialized := True;
end;

procedure TDataSetGPUFilter.CleanupGL;
begin
  if FRC <> 0 then
  begin
    wglMakeCurrent(FDC, FRC);
    if FInputSSBO <> 0 then
      glDeleteBuffers(1, @FInputSSBO);
    if FOutputSSBO <> 0 then
      glDeleteBuffers(1, @FOutputSSBO);
    if FCounterSSBO <> 0 then
      glDeleteBuffers(1, @FCounterSSBO);
    if FProgram <> 0 then
      glDeleteProgram(FProgram);
    wglMakeCurrent(0, 0);
    wglDeleteContext(FRC);
    FRC := 0;
  end;
  if (FDC <> 0) and (FDummyWnd <> 0) then
    ReleaseDC(FDummyWnd, FDC);
  if FDummyWnd <> 0 then
    DestroyWindow(FDummyWnd);
  FInitialized := False;
end;

function TDataSetGPUFilter.CompileComputeShader(const ASource: string): GLuint;
var
  SrcAnsi: UTF8String;
  PSrc: PGLchar;
  Status, LogLen: GLint;
  LogBuf: TBytes;
begin
  Result := glCreateShader(GL_COMPUTE_SHADER);
  SrcAnsi := UTF8String(ASource);
  PSrc := PGLchar(SrcAnsi);
  glShaderSource(Result, 1, @PSrc, nil);
  glCompileShader(Result);

  glGetShaderiv(Result, GL_COMPILE_STATUS, @Status);
  if Status = 0 then
  begin
    glGetShaderiv(Result, GL_INFO_LOG_LENGTH, @LogLen);
    SetLength(LogBuf, LogLen);
    glGetShaderInfoLog(Result, LogLen, nil, Pointer(LogBuf));
    glDeleteShader(Result);
    raise Exception.Create('Compute Shader compile error: ' + TEncoding.UTF8.GetString(LogBuf));
  end;
end;

class procedure TDataSetGPUFilter.PackText16(const AText: string; out P0, P1, P2, P3: UInt32);
var
  Upper: string;
  I, Len, WordIdx, Shift: Integer;
  Ch: Byte;
begin
  P0 := 0;
  P1 := 0;
  P2 := 0;
  P3 := 0;
  Upper := UpperCase(Trim(AText));
  Len := Length(Upper);
  if Len > 16 then
    Len := 16;
// Pack up to 16 uppercase ASCII characters into 4x 32-bit unsigned integers
  for I := 1 to Len do
  begin
    if Ord(Upper[I]) <= 255 then
      Ch := Byte(Ord(Upper[I]))
    else
      Ch := Ord('?');
    WordIdx := (I - 1) shr 2;
    Shift := ((I - 1) and 3) * 8;
    case WordIdx of
      0:
        P0 := P0 or (UInt32(Ch) shl Shift);
      1:
        P1 := P1 or (UInt32(Ch) shl Shift);
      2:
        P2 := P2 or (UInt32(Ch) shl Shift);
      3:
        P3 := P3 or (UInt32(Ch) shl Shift);
    end;
  end;
end;

procedure TDataSetGPUFilter.Attach(ADataSet: TDataSet;
  const ACatField, AAmountField, ATextField: string);
var
  Rows: array of TGPUDataRow;
  FldCat, FldAmount, FldText: TField;
  Idx: Integer;
  Bm: TBookmark;
begin
  if not FInitialized then Exit;

  ADataSet.DisableControls;
  Bm := ADataSet.GetBookmark;
  try
    FRowCount := ADataSet.RecordCount;
    SetLength(Rows, FRowCount);

    FldCat := ADataSet.FieldByName(ACatField);
    FldAmount := ADataSet.FieldByName(AAmountField);
    FldText := ADataSet.FieldByName(ATextField);

    // Iterate through the DataSet once and pack all rows into a flat 32-byte structure
    Idx := 0;
    ADataSet.First;
    while not ADataSet.Eof do
    begin
      if Idx >= Length(Rows) then
        SetLength(Rows, Length(Rows) + 65536);

      Rows[Idx].RecNo := Idx + 1;
      Rows[Idx].Category := FldCat.AsInteger;
      Rows[Idx].Amount := FldAmount.AsFloat;
      Rows[Idx].Reserved := 0;
      PackText16(FldText.AsString,
        Rows[Idx].TextPack0, Rows[Idx].TextPack1, Rows[Idx].TextPack2, Rows[Idx].TextPack3);

      Inc(Idx);
      ADataSet.Next;
    end;
    FRowCount := Idx;

    // Upload the flattened row buffer into GPU VRAM (SSBO Binding 0)
    wglMakeCurrent(FDC, FRC);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, FInputSSBO);
    if FRowCount > 0 then
      glBufferData(GL_SHADER_STORAGE_BUFFER, FRowCount * SizeOf(TGPUDataRow), Pointer(Rows), GL_STATIC_DRAW)
    else
      glBufferData(GL_SHADER_STORAGE_BUFFER, 32, nil, GL_STATIC_DRAW);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  finally
    if ADataSet.BookmarkValid(Bm) then
      ADataSet.GotoBookmark(Bm);
    ADataSet.FreeBookmark(Bm);
    ADataSet.EnableControls;
  end;
end;

function TDataSetGPUFilter.Filter(const ASearchText: string; ACategory: Integer; AMinAmount: Single; out ATotalMatches: Integer): TArray<Integer>;
var
  CountVal, MaxVal: UInt32;
  SP0, SP1, SP2, SP3: UInt32;
  CleanSearch: string;
  SearchLen, Groups, CopyCount: Integer;
begin
  ATotalMatches := 0;
  Result := nil;
  if (not FInitialized) or (FRowCount <= 0) then
    Exit;
  wglMakeCurrent(FDC, FRC);
// Reset atomic match counter in SSBO Binding 2
  CountVal := 0;
  MaxVal := UInt32(FMaxResults);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FCounterSSBO);
  glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, SizeOf(UInt32), @CountVal);
  glBufferSubData(GL_SHADER_STORAGE_BUFFER, SizeOf(UInt32), SizeOf(UInt32), @MaxVal);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FInputSSBO);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, FOutputSSBO);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, FCounterSSBO);
  CleanSearch := UpperCase(Trim(ASearchText));
  SearchLen := Length(CleanSearch);
  if SearchLen > 16 then
    SearchLen := 16;
  PackText16(CleanSearch, SP0, SP1, SP2, SP3);
  glUseProgram(FProgram);
  glUniform1i(FLocRowCount, FRowCount);
  glUniform1i(FLocCategory, ACategory);
  glUniform1f(FLocMinAmount, AMinAmount);
  glUniform1i(FLocSearchLen, SearchLen);
  glUniform4ui(FLocSearchPack, SP0, SP1, SP2, SP3);
// Dispatch 1 thread per row (256 threads per workgroup)
  Groups := (FRowCount + 255) div 256;
  glDispatchCompute(Groups, 1, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
// Read back total match count and matching row indices
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FCounterSSBO);
  glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, SizeOf(UInt32), @CountVal);
  ATotalMatches := Integer(CountVal);
  CopyCount := ATotalMatches;
  if CopyCount > FMaxResults then
    CopyCount := FMaxResults;
  if CopyCount > 0 then
  begin
    SetLength(Result, CopyCount);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, FOutputSSBO);
    glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, CopyCount * SizeOf(Int32), Pointer(Result));
  end;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  glUseProgram(0);
end;

end.

