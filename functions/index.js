const functions = require('firebase-functions');
const admin = require('firebase-admin');
const crypto = require('crypto');

admin.initializeApp();

// Secure passcode validation function
exports.validateRegistrationPasscode = functions.https.onCall(async (data, context) => {
    const { passcode } = data;

    // Security: Verify App Check token (optional but recommended)
    if (context.app === undefined) {
        throw new functions.https.HttpsError(
            'failed-precondition',
            'The function must be called from an App Check verified app.'
        );
    }

    // Input validation
    if (!passcode || typeof passcode !== 'string') {
        throw new functions.https.HttpsError(
            'invalid-argument',
            'Please provide a valid registration passcode'
        );
    }

    const normalizedPasscode = passcode.trim().toUpperCase();

    if (normalizedPasscode.length === 0) {
        throw new functions.https.HttpsError(
            'invalid-argument',
            'Please enter a registration passcode'
        );
    }

    try {
        // Hash the passcode for comparison (if you want to store hashed passcodes)
        // const hashedPasscode = crypto.createHash('sha256').update(normalizedPasscode).digest('hex');

        // Query the admins collection securely (server-side only)
        const adminQuery = await admin.firestore()
            .collection('admins')
            .where('registrationPasscode', '==', normalizedPasscode)
            .where('active', '==', true) // Only active admins
            .limit(1)
            .get();

        if (adminQuery.empty) {
            // Rate limiting: Add delay to prevent brute force
            await new Promise(resolve => setTimeout(resolve, 1000));

            throw new functions.https.HttpsError(
                'not-found',
                'Invalid registration passcode'
            );
        }

        const adminDoc = adminQuery.docs[0];
        const adminData = adminDoc.data();

        // Return minimal necessary data
        return {
            isValid: true,
            adminId: adminDoc.id,
            adminName: adminData.name || 'Unknown Admin'
        };

    } catch (error) {
        console.error('Passcode validation error:', error);

        if (error instanceof functions.https.HttpsError) {
            throw error;
        }

        throw new functions.https.HttpsError(
            'internal',
            'Error validating passcode'
        );
    }
});

// Enhanced user creation function with server-side validation
exports.createUserWithPasscode = functions.https.onCall(async (data, context) => {
    const { email, password, name, passcode } = data;

    // Security: Verify App Check token (optional but recommended)
    if (context.app === undefined) {
        throw new functions.https.HttpsError(
            'failed-precondition',
            'The function must be called from an App Check verified app.'
        );
    }

    // Validate inputs
    if (!email || !password || !passcode) {
        throw new functions.https.HttpsError(
            'invalid-argument',
            'Email, password, and passcode are required'
        );
    }

    try {
        // First validate the passcode server-side
        const passcodeResult = await exports.validateRegistrationPasscode.run({ passcode });

        if (!passcodeResult.isValid) {
            throw new functions.https.HttpsError(
                'permission-denied',
                'Invalid registration passcode'
            );
        }

        // Create the user account
        const userRecord = await admin.auth().createUser({
            email: email,
            password: password,
            displayName: name || ''
        });

        // Create user document in Firestore
        const now = new Date();
        await admin.firestore().collection('users').doc(userRecord.uid).set({
            name: name || '',
            contact: email,
            contactType: 'email',
            notes: '',
            planIds: [],
            // No 'active' field - indicates new user pending admin review
            adminId: passcodeResult.adminId,
            firstLoginTime: now.toISOString(),
            lastLoginTime: now.toISOString(),
            registrationDate: now.toISOString()
        });

        return {
            success: true,
            userId: userRecord.uid,
            message: 'Registration successful! Please wait for admin approval.'
        };

    } catch (error) {
        console.error('User creation error:', error);

        if (error instanceof functions.https.HttpsError) {
            throw error;
        }

        throw new functions.https.HttpsError(
            'internal',
            'Registration failed'
        );
    }
});
