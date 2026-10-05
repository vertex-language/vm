package windows

/// Generates an unattended setup configuration (autounattend.xml) that automatically bypasses
/// TPM 2.0, Secure Boot, CPU, and RAM checks for Windows 11 virtual machines.
public func GenerateAutoUnattendXml() -> string {
    return """
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
    </settings>
</unattend>
"""
}

/// Registry command string to apply LabConfig bypass manually in Windows Setup (Shift+F10 console).
public let LabConfigRegistryCommands: string = """
reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f
reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f
"""
