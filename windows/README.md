# CertMate Windows - Windows-native distribution build pipeline.

Run Build-Release.ps1 to produce a signed installer exe.
Run Test-Package.ps1 to run the release verification battery.
Run Check-Update.ps1 to compare installed version against latest stable.
Run Invoke-Update.ps1 to stage and install an update with rollback.
Run Verify-Tree.ps1 to confirm the source tree is complete and consistent.
