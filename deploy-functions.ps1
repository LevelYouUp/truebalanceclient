# PowerShell script to deploy Cloud Functions securely

Write-Host "Deploying TrueBalance Cloud Functions..." -ForegroundColor Green

# Navigate to functions directory
Set-Location "functions"

# Install dependencies
Write-Host "Installing dependencies..." -ForegroundColor Yellow
npm install

# Deploy functions
Write-Host "Deploying to Firebase..." -ForegroundColor Yellow
firebase deploy --only functions

# Return to root directory
Set-Location ".."

Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "Functions deployed:" -ForegroundColor Cyan
Write-Host "  - validateRegistrationPasscode" -ForegroundColor White
Write-Host "  - createUserWithPasscode" -ForegroundColor White

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "1. Update Firestore security rules" -ForegroundColor White
Write-Host "2. Configure App Check (optional but recommended)" -ForegroundColor White
Write-Host "3. Test the functions from your Flutter app" -ForegroundColor White
