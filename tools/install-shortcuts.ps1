# Creates/refreshes the "Video Studio" shortcuts (Desktop + Start Menu) with the
# app icon AND the matching AppUserModelID, so the app pins to the taskbar
# correctly (custom icon, and it launches the app instead of an empty terminal).
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ico   = Join-Path $Root 'VideoStudio.ico'
$vbs   = Join-Path $Root 'Video Studio.vbs'
$AppId = 'NachumMarkov.VideoStudio'   # MUST match $script:AppId in Studio.ps1

# --- helper to stamp System.AppUserModel.ID onto a .lnk. Must load the shortcut
#     via IPersistFile, set the property on its IPropertyStore, then SAVE it back
#     (setting a property store obtained from the path alone does NOT persist).
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct PROPERTYKEY { public Guid fmtid; public uint pid; }

[ComImport, Guid("00021401-0000-0000-C000-000000000046")]
public class CShellLink {}

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
public interface IPersistFile {
    void GetClassID(out Guid pClassID);
    [PreserveSig] int IsDirty();
    void Load([MarshalAs(UnmanagedType.LPWStr)] string f, int mode);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string f, [MarshalAs(UnmanagedType.Bool)] bool remember);
    void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string f);
    void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string f);
}

// PROPVARIANT is passed as a raw pointer we build by hand - marshalling it as a
// struct silently fails to persist the string on x64.
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")]
public interface IPropertyStore {
    [PreserveSig] int GetCount(out uint c);
    [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
    [PreserveSig] int GetValue(ref PROPERTYKEY k, IntPtr pv);
    [PreserveSig] int SetValue(ref PROPERTYKEY k, IntPtr pv);
    [PreserveSig] int Commit();
}

public static class LnkAumid {
    public static void Set(string lnkPath, string appId) {
        var link = new CShellLink();
        var pf = (IPersistFile)link;
        pf.Load(lnkPath, 2 /*STGM_READWRITE*/);
        var store = (IPropertyStore)link;
        var key = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
        IntPtr pv = Marshal.AllocCoTaskMem(16);
        for (int i = 0; i < 16; i++) Marshal.WriteByte(pv, i, 0);
        IntPtr str = Marshal.StringToCoTaskMemUni(appId);
        Marshal.WriteInt16(pv, 0, 31 /*VT_LPWSTR*/);
        Marshal.WriteIntPtr(pv, 8, str);
        store.SetValue(ref key, pv);
        store.Commit();
        pf.Save(lnkPath, true);
        Marshal.FreeCoTaskMem(str);
        Marshal.FreeCoTaskMem(pv);
        Marshal.ReleaseComObject(link);
    }
}
'@

function New-VSShortcut([string]$lnkPath) {
    $dir = Split-Path -Parent $lnkPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $sh = New-Object -ComObject WScript.Shell
    $s  = $sh.CreateShortcut($lnkPath)
    $s.TargetPath       = 'wscript.exe'
    $s.Arguments        = '"' + $vbs + '"'
    $s.WorkingDirectory = $Root
    $s.IconLocation     = "$ico,0"
    $s.Description       = 'Video Studio'
    $s.Save()
    [LnkAumid]::Set($lnkPath, $AppId)   # stamp AppUserModelID so pinning works
    Write-Host "  wrote $lnkPath"
}

$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Video Studio.lnk'),
    (Join-Path (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs') 'Video Studio.lnk')
)
Write-Host "Installing Video Studio shortcuts (icon + AppUserModelID '$AppId')..."
foreach ($t in $targets) { try { New-VSShortcut $t } catch { Write-Host "  FAILED $t : $($_.Exception.Message)" } }
Write-Host "Done. Unpin the old taskbar pin, open Video Studio, then pin it again (or pin the Start Menu entry)."
