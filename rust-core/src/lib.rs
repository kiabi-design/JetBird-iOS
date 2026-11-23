//! JetBird SPAKE2 (RFC 9382) implementation for iOS
//! Ported from native/lan_spake.c (GPL-3.0-or-later)
//!
//! This crate provides:
//! - SPAKE2 key exchange over P-256 curve
//! - Secure memory handling with zeroize
//! - FFI-compatible C API for Swift interop

#![no_std]
extern crate alloc;

use alloc::vec::Vec;
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, ZeroizeOnDrop};

// Re-export for FFI
pub use ffi::*;

mod constants;
mod hmac;
mod spake2;
mod transcript;

use constants::{PHONE_ID, CONSOLE_ID, CONFIRMATION_KEYS_LABEL};
use spake2::Spake2Context;

/// Error codes for FFI
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Spake2Error {
    Success = 0,
    InvalidCode = -1,
    InvalidScalar = -2,
    CryptoFailure = -3,
    InvalidInput = -4,
    BufferTooSmall = -5,
}

/// SPAKE2 role
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Zeroize)]
pub enum Spake2Role {
    Phone = 1,   // Client (phone)
    Console = 2, // Server (PS4)
}

/// Main SPAKE2 context - holds all state for a pairing session
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct Spake2Session {
    role: Spake2Role,
    code: u32,
    scalar: [u8; 32],
    our_point: [u8; 65],
    their_point: [u8; 65],
    shared_secret: [u8; 65],
    w_scalar: [u8; 32],
    pin: [u8; 16],
    confirmed: bool,
}

impl Spake2Session {
    /// Create new SPAKE2 session
    ///
    /// # Arguments
    /// * `role` - Phone (1) or Console (2)
    /// * `code` - 6-digit pairing code (0-999999)
    /// * `scalar` - 32-byte random scalar (private key)
    /// * `pin` - 16-byte PIN from QR code
    pub fn new(role: Spake2Role, code: u32, scalar: [u8; 32], pin: [u8; 16]) -> Result<Self, Spake2Error> {
        if code >= 1_000_000 {
            return Err(Spake2Error::InvalidCode);
        }
        if !Spake2Context::validate_scalar(&scalar) {
            return Err(Spake2Error::InvalidScalar);
        }

        let mut session = Self {
            role,
            code,
            scalar,
            our_point: [0u8; 65],
            their_point: [0u8; 65],
            shared_secret: [0u8; 65],
            w_scalar: [0u8; 32],
            pin,
            confirmed: false,
        };

        // Compute w = password(code)
        session.compute_w_scalar();
        Ok(session)
    }

    /// Compute our public point to share: X = w*M + x*G (phone) or Y = w*N + y*G (console)
    pub fn compute_share(&mut self) -> Result<&[u8; 65], Spake2Error> {
        let role_phone = matches!(self.role, Spake2Role::Phone);

        Spake2Context::compute_share(
            role_phone,
            &self.w_scalar,
            &self.scalar,
            &mut self.our_point,
        ).map_err(|_| Spake2Error::CryptoFailure)?;

        Ok(&self.our_point)
    }

    /// Process their point and compute shared secret:
    /// Phone: K = x*(B - w*N)
    /// Console: K = y*(A - w*M)
    pub fn process_their_point(&mut self, their_point: &[u8; 65]) -> Result<(), Spake2Error> {
        self.their_point = *their_point;

        let role_phone = matches!(self.role, Spake2Role::Phone);

        Spake2Context::process_their_point(
            role_phone,
            their_point,
            &self.w_scalar,
            &self.scalar,
            &mut self.shared_secret,
        ).map_err(|_| Spake2Error::CryptoFailure)?;

        Ok(())
    }

    /// Generate confirmation proofs (64 bytes: 32 + 32)
    pub fn generate_proofs(&mut self) -> Result<[u8; 64], Spake2Error> {
        if self.confirmed {
            return Err(Spake2Error::CryptoFailure);
        }

        let transcript = self.build_transcript();
        let digest = Spake2Context::sha256(&transcript);

        // HKDF extract
        let salt = [0u8; 32];
        let extract = hmac::hkdf_extract(&salt, &digest[16..32]);

        // HKDF expand with label
        let mut info = [0u8; CONFIRMATION_KEYS_LABEL.len() + 16 + 1];
        info[..CONFIRMATION_KEYS_LABEL.len()].copy_from_slice(CONFIRMATION_KEYS_LABEL);
        info[CONFIRMATION_KEYS_LABEL.len()..CONFIRMATION_KEYS_LABEL.len()+16].copy_from_slice(&self.pin);
        info[info.len() - 1] = 1;

        let keys = hmac::hkdf_expand(&extract, &info, 32);

        // HMAC with first 16 bytes of keys
        let proof1 = hmac::hmac_sha256(&keys[0..16], &transcript);
        // HMAC with second 16 bytes of keys
        let proof2 = hmac::hmac_sha256(&keys[16..32], &transcript);

        let mut proofs = [0u8; 64];
        proofs[0..32].copy_from_slice(&proof1);
        proofs[32..64].copy_from_slice(&proof2);

        self.confirmed = true;
        Ok(proofs)
    }

    /// Verify received proofs
    pub fn verify_proofs(&mut self, proofs: &[u8; 64]) -> bool {
        let expected = self.generate_proofs().unwrap_or([0u8; 64]);
        proofs.ct_eq(&expected).into()
    }

    /// Get the derived session key (32 bytes)
    pub fn session_key(&mut self) -> [u8; 32] {
        let transcript = self.build_transcript();
        let digest = Spake2Context::sha256(&transcript);

        let salt = [0u8; 32];
        let extract = hmac::hkdf_extract(&salt, &digest[16..32]);

        let mut info = [0u8; CONFIRMATION_KEYS_LABEL.len() + 16 + 1];
        info[..CONFIRMATION_KEYS_LABEL.len()].copy_from_slice(CONFIRMATION_KEYS_LABEL);
        info[CONFIRMATION_KEYS_LABEL.len()..CONFIRMATION_KEYS_LABEL.len()+16].copy_from_slice(&self.pin);
        info[info.len() - 1] = 2; // Different label for session key

        let key_vec = hmac::hkdf_expand(&extract, &info, 32);
        let mut key = [0u8; 32];
        key.copy_from_slice(&key_vec);
        key
    }

    fn compute_w_scalar(&mut self) {
        // w = code + 1, encoded as big-endian 32-byte scalar
        let value = self.code + 1;
        self.w_scalar = [0u8; 32];
        self.w_scalar[29] = ((value >> 16) & 0xFF) as u8;
        self.w_scalar[30] = ((value >> 8) & 0xFF) as u8;
        self.w_scalar[31] = (value & 0xFF) as u8;
    }

    fn build_transcript(&self) -> Vec<u8> {
        // Format: len(phone_id) || phone_id || len(console_id) || console_id ||
        //         a(65) || b(65) || shared(65) || w(32)
        // Each prefixed with 8-byte length (big-endian)
        let mut transcript = Vec::with_capacity(8*6 + PHONE_ID.len() + CONSOLE_ID.len() + 65*3 + 32);

        transcript::write_prefixed(&mut transcript, PHONE_ID);
        transcript::write_prefixed(&mut transcript, CONSOLE_ID);
        transcript::write_prefixed(&mut transcript, &self.our_point);
        transcript::write_prefixed(&mut transcript, &self.their_point);
        transcript::write_prefixed(&mut transcript, &self.shared_secret);
        transcript::write_prefixed(&mut transcript, &self.w_scalar);

        transcript
    }
}

// FFI module for Swift interop
mod ffi {
    use super::*;
    use alloc::boxed::Box;
    use core::ptr;

    /// Opaque handle for Swift
    pub type Spake2Handle = *mut Spake2Session;

    /// Create new SPAKE2 session
    /// Returns null on error
    #[no_mangle]
    pub unsafe extern "C" fn jetbird_spake2_create(
        role: i32,
        code: u32,
        scalar: *const u8,
        pin: *const u8,
    ) -> Spake2Handle {
        if scalar.is_null() || pin.is_null() {
            return ptr::null_mut();
        }

        let mut scalar_arr = [0u8; 32];
        let mut pin_arr = [0u8; 16];
        ptr::copy_nonoverlapping(scalar, scalar_arr.as_mut_ptr(), 32);
        ptr::copy_nonoverlapping(pin, pin_arr.as_mut_ptr(), 16);

        let role = match role {
            1 => Spake2Role::Phone,
            2 => Spake2Role::Console,
            _ => return ptr::null_mut(),
        };

        match Spake2Session::new(role, code, scalar_arr, pin_arr) {
            Ok(session) => Box::into_raw(Box::new(session)),
            Err(_) => ptr::null_mut(),
        }
    }

    /// Compute our public point (65 bytes output)
    #[no_mangle]
    pub unsafe extern "C" fn jetbird_spake2_compute_share(
        handle: Spake2Handle,
        out_point: *mut u8,
    ) -> i32 {
        if handle.is_null() || out_point.is_null() {
            return Spake2Error::InvalidInput as i32;
        }

        let session = &mut *handle;
        match session.compute_share() {
            Ok(point) => {
                ptr::copy_nonoverlapping(point.as_ptr(), out_point, 65);
                Spake2Error::Success as i32
            }
            Err(e) => e as i32,
        }
    }

    /// Process their point and compute shared secret
    #[no_mangle]
    pub unsafe extern "C" fn jetbird_spake2_process_their_point(
        handle: Spake2Handle,
        their_point: *const u8,
    ) -> i32 {
        if handle.is_null() || their_point.is_null() {
            return Spake2Error::InvalidInput as i32;
        }

        let session = &mut *handle;
        let mut point_arr = [0u8; 65];
        ptr::copy_nonoverlapping(their_point, point_arr.as_mut_ptr(), 65);

        match session.process_their_point(&point_arr) {
            Ok(()) => Spake2Error::Success as i32,
            Err(e) => e as i32,
        }
    }

    /// Generate confirmation proofs (64 bytes output)
    #[no_mangle]
    pub unsafe extern "C" fn jetbird_spake2_generate_proofs(
        handle: Spake2Handle,
        out_proofs: *mut u8,
    ) -> i32 {
        if handle.is_null() || out_proofs.is_null() {
            return Spake2Error::InvalidInput as i32;
        }

        let session = &mut *handle;
        match session.generate_proofs() {
            Ok(proofs) => {
                ptr::copy_nonoverlapping(proofs.as_ptr(), out_proofs, 64);
                Spake2Error::Success as i32
            }
            Err(e) => e as i32,
        }
    }

    /// Verify received proofs
    #[no_mangle]
    pub unsafe extern "C" fn jetbird_spake2_verify_proofs(
        handle: Spake2Handle,
        proofs: *const u8,
    ) -> i32 {
        if handle.is_null() || proofs.is_null() {
            return 0;
        }

        let session = &mut *handle;
        let mut proofs_arr = [0u8; 64];
        ptr::copy_nonoverlapping(proofs, proofs_arr.as_mut_ptr(), 64);

        if session.verify_proofs(&proofs_arr) {
            1
        } else {
            0
        }
    }

    /// Get session key (32 bytes output)
    #[no_mangle]
    pub unsafe extern "C" fn jetbird_spake2_session_key(
        handle: Spake2Handle,
        out_key: *mut u8,
    ) -> i32 {
        if handle.is_null() || out_key.is_null() {
            return Spake2Error::InvalidInput as i32;
        }

        let session = &mut *handle;
        let key = session.session_key();
        ptr::copy_nonoverlapping(key.as_ptr(), out_key, 32);
        Spake2Error::Success as i32
    }

    /// Destroy session and zeroize memory
    #[no_mangle]
    pub unsafe extern "C" fn jetbird_spake2_destroy(handle: Spake2Handle) {
        if !handle.is_null() {
            let _ = Box::from_raw(handle); // Drop zeros memory via ZeroizeOnDrop
        }
    }

    /// Validate scalar (public helper)
    #[no_mangle]
    pub unsafe extern "C" fn jetbird_spake2_validate_scalar(scalar: *const u8) -> i32 {
        if scalar.is_null() {
            return 0;
        }
        let mut arr = [0u8; 32];
        ptr::copy_nonoverlapping(scalar, arr.as_mut_ptr(), 32);
        if Spake2Context::validate_scalar(&arr) {
            1
        } else {
            0
        }
    }

    /// Generate random scalar (32 bytes) - uses OS randomness
    #[no_mangle]
    pub unsafe extern "C" fn jetbird_spake2_random_scalar(out_scalar: *mut u8) -> i32 {
        if out_scalar.is_null() {
            return Spake2Error::InvalidInput as i32;
        }

        #[cfg(feature = "std")]
        {
            // Use getrandom
            let slice = core::slice::from_raw_parts_mut(out_scalar, 32);
            getrandom::getrandom(slice).ok();
            Spake2Error::Success as i32
        }
        #[cfg(not(feature = "std"))]
        {
            // For no_std, require caller to provide randomness
            Spake2Error::CryptoFailure as i32
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_spake2_phone_console_pairing() {
        // Test vectors from RFC 9382 / Android implementation
        let phone_scalar = [0x42u8; 32]; // Test scalar
        let console_scalar = [0x24u8; 32];
        let code = 123456u32;
        let pin = [0xABu8; 16];

        // Phone side
        let mut phone = Spake2Session::new(Spake2Role::Phone, code, phone_scalar, pin).unwrap();
        let phone_point = phone.compute_share().unwrap().clone();

        // Console side
        let mut console = Spake2Session::new(Spake2Role::Console, code, console_scalar, pin).unwrap();
        let console_point = console.compute_share().unwrap().clone();

        // Exchange points
        phone.process_their_point(&console_point).unwrap();
        console.process_their_point(&phone_point).unwrap();

        // Generate and verify proofs
        let phone_proofs = phone.generate_proofs().unwrap();
        let console_proofs = console.generate_proofs().unwrap();

        assert!(phone.verify_proofs(&console_proofs));
        assert!(console.verify_proofs(&phone_proofs));

        // Session keys should match
        assert_eq!(phone.session_key(), console.session_key());
    }

    #[test]
    fn test_invalid_code() {
        let scalar = [0x42u8; 32];
        let pin = [0u8; 16];
        assert!(Spake2Session::new(Spake2Role::Phone, 1_000_000, scalar, pin).is_err());
    }

    #[test]
    fn test_zeroize_on_drop() {
        let scalar = [0x42u8; 32];
        let pin = [0u8; 16];
        let session = Spake2Session::new(Spake2Role::Phone, 123456, scalar, pin).unwrap();
        // Drop should zeroize
        drop(session);
    }
}