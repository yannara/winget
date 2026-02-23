# Winget
Use Winget to install and update your apps for Windows. Winget is command line utility for app install, update and uninstall automation. 

⚠️ **THIS FREE PRODUCT IS PROVIDED “AS IS”, WITHOUT ANY WARRANTIES, GUARANTEES, OR RIGHTS TO CLAIM OR COMPENSATION. PLEASE UNDERSTAND THAT FREE SOLUTIONS ARE NOT PERFECT.** ⚠️

# Winget Install
Use this script as Win32 app in Intune or Remediation Script to push any new installation of applications. You can use "Winget Search xXx" first from any Windows to find the desired app and valid ID for it. Then add the ID to the script and deploy it with Intune or SCCM. This solution is also OSD and Autopilot friendly. Multiple apps can be added to the same script. The example of add-on is in the script.
For troubleshooting, use Event Viewer/Application node to monitor how the process is executed.
<br>
<img width="580" height="114" alt="image" src="https://github.com/user-attachments/assets/16c887dc-c05d-4696-8348-b62a2a857890" />




# Winget Update Any Apps
Use this script to publish Scheduled Task which will launch the Winget process each day at 11.00 am to seek for new application updates available. You can only limit some applications which you don't want to update, as example, few Microsoft components are added in the script as non-updatable. For troubleshooting, use Event Viewer/Application node to monitor how the process is executed.
<br>
<img width="843" height="190" alt="image" src="https://github.com/user-attachments/assets/500bd61b-d76d-4e64-90d7-30d50048ddbe" />

# Documentation
Detailed instructions and more info will be published in Linkedin in few days.
