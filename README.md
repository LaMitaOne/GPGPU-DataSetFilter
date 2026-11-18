# GPGPU-DataSetFilter
    
A lightweight, zero-dependency **OpenGL 4.3 Compute Shader** filter for standard Delphi `TDataSet` components (`TFDMemTable`, `TFDQuery`, `TClientDataSet`, etc.).     
     
It demonstrates how to use modern **GPGPU (General-Purpose Computing on Graphics Processing Units)** in pure Delphi VCL applications—without any rendering window, external DLLs, CUDA, or OpenCL—to filter and search **millions of database records in just a few milliseconds**.     
    
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/GPGPU-DataSetFilter)    
     
<img width="960" height="629" alt="Unbenannt" src="https://github.com/user-attachments/assets/c1b536a5-ea32-43ad-89f3-3d9cdb154b3f" />
     
## Benchmark (1,000,000 Rows — Ryzen 5 4500U Integrated Vega 6)     
     
Searching 1,000,000 records for substring `"yuta"` (`99,131` matches):     
     
| Method | Matches | Duration | Speedup |     
| :--- | :---: | :---: | :---: |     
| **Classic CPU Loop (`TDataSet` scan)** | 99,131 | `623.90 ms` | 1× |     
| **GPU Compute Shader (`uDataSetGPUFilter`)** | 99,131 | **`3.69 ms`** | **~169× faster** |     
     
## How It Works     
     
1. **Headless OpenGL 4.3 Core Context:** `TDataSetGPUFilter` creates an invisible 1×1 dummy window (`STATIC`) to initialize an OpenGL 4.3 Core Profile context. No visible OpenGL viewport or game engine is required.       
2. **Data-Oriented `std430` SSBO Layout:** `Attach()` reads the target columns from any `TDataSet` once and packs each row into a cache-friendly **32-byte struct** (`RecNo`, `Category`, `Amount`, and up to 16 uppercase ASCII characters packed into `uvec4`) uploaded to VRAM.           
3. **Parallel Compute Dispatch:** `Filter()` dispatches 256-thread workgroups across all rows simultaneously. Matching row indices are collected via atomic counters (`atomicAdd`) into an output SSBO and read back to Delphi to drive `TDBGrid` via a fast `O(1)` lookup bitmask.      
      

## Quick Start      

      

```pascal      

// 1. Initialize once (creates headless OpenGL 4.3 context)
FGPUFilter := TDataSetGPUFilter.Create(100000);

// 2. Upload any opened TDataSet once into VRAM
FGPUFilter.Attach(MyFDQuery, 'Category', 'Amount', 'ProductName');

// 3. Query in real time (e.g. inside TEdit.OnChange)
Hits := FGPUFilter.Filter('YUTA', 0, 0.0, TotalMatches);
```
     
## Requirements     
     
* **Delphi** (VCL / FireDAC for the included demo; `uDataSetGPUFilter.pas` itself only requires standard `Data.DB` and `Winapi.OpenGLext`).     
* Any Windows GPU/driver supporting **OpenGL 4.3+** (NVIDIA, AMD, or Intel integrated graphics).     
* **No third-party DLLs** required.


 Exe and sample project included    
      
## Tip: Automatic GPU Capability & Fallback Detection      
     
Before dispatching millions of rows in a production application, you may want to check whether the user's machine supports OpenGL 4.3 Compute Shaders, verify available VRAM (`Max SSBO Size`), or fall back to a classic CPU loop on older office hardware/VMs.     
     
Check out **[Yutani-GPUInfo](https://github.com/LaMitaOne/Yutani-GPUInfo)** — a companion single-file, zero-dependency Delphi unit that detects OpenGL 4.3+ compute support, available VRAM, and real-world compute shader speed in ~15 ms.    
      
