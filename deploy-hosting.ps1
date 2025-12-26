# Firebase Hosting Deployment Script
# This script deploys your privacy policy to Firebase Hosting

Write-Host "Deploying to Firebase Hosting..." -ForegroundColor Green

# Check if Firebase CLI is installed
$firebaseInstalled = Get-Command firebase -ErrorAction SilentlyContinue

if (-not $firebaseInstalled) {
    Write-Host "Firebase CLI not found. Installing..." -ForegroundColor Yellow
    npm install -g firebase-tools
}

# Login to Firebase (if not already logged in)
Write-Host "`nLogging in to Firebase..." -ForegroundColor Cyan
firebase login

# Initialize hosting if needed
Write-Host "`nEnsuring hosting is initialized..." -ForegroundColor Cyan
firebase use true-balance-8dac7

# Deploy to Firebase Hosting
Write-Host "`nDeploying to Firebase Hosting..." -ForegroundColor Cyan
firebase deploy --only hosting

Write-Host "`nDeployment complete!" -ForegroundColor Green
Write-Host "Your privacy policy will be available at:" -ForegroundColor Green
Write-Host "https://true-balance-8dac7.web.app/privacy-policy.html" -ForegroundColor Cyan
Write-Host "or" -ForegroundColor Gray
Write-Host "https://true-balance-8dac7.firebaseapp.com/privacy-policy.html" -ForegroundColor Cyan
