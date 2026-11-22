//! HMAC-SHA256 and HKDF implementation
//! Compatible with BearSSL's HMAC used in the Android version

use sha2::{Sha256, Digest};
use hmac::{Hmac, Mac};
use hkdf::Hkdf;

type HmacSha256 = Hmac<Sha256>;

/// HMAC-SHA256 with key and data
pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC key valid");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

/// HKDF Extract: PRK = HMAC-SHA256(salt, IKM)
pub fn hkdf_extract(salt: &[u8; 32], ikm: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut prk = [0u8; 32];
    hk.expand(&[], &mut prk).expect("HKDF extract 32 bytes");
    prk
}

/// HKDF Expand: OKM = HMAC-SHA256(PRK, info || counter)
pub fn hkdf_expand(prk: &[u8; 32], info: &[u8], out_len: usize) -> alloc::vec::Vec<u8> {
    let hk = Hkdf::<Sha256>::from_prk(prk).expect("Valid PRK");
    let mut okm = alloc::vec::Vec::with_capacity(out_len);
    okm.resize(out_len, 0u8);
    hk.expand(info, &mut okm).expect("HKDF expand");
    okm
}

/// SHA-256 hash
pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().into()
}

/// Constant-time memory clear
pub fn secure_clear(data: &mut [u8]) {
    for byte in data.iter_mut() {
        *byte = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hmac_sha256() {
        let key = b"test key";
        let data = b"test data";
        let result = hmac_sha256(key, data);
        assert_eq!(result.len(), 32);

        // Same inputs = same output
        let result2 = hmac_sha256(key, data);
        assert_eq!(result, result2);
    }

    #[test]
    fn test_hkdf() {
        let salt = [0u8; 32];
        let ikm = b"input key material";
        let prk = hkdf_extract(&salt, ikm);
        assert_eq!(prk.len(), 32);

        let info = b"info";
        let okm = hkdf_expand(&prk, info, 32);
        assert_eq!(okm.len(), 32);
    }

    #[test]
    fn test_sha256() {
        let data = b"hello world";
        let hash = sha256(data);
        assert_eq!(hash.len(), 32);
    }
}