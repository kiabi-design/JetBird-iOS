//! SPAKE2 core cryptographic operations using p256 crate v0.13
//! Implements RFC 9382 SPAKE2 over P-256 curve (asymmetric variant)

use p256::{
    elliptic_curve::{
        group::Group,
        sec1::{FromEncodedPoint, ToEncodedPoint},
        AffinePoint, ProjectivePoint, Scalar,
    },
    NistP256,
};
use subtle::{Choice, CtOption};
use p256::elliptic_curve::PrimeField;

use crate::constants::{M_POINT, M_NEG, N_POINT, N_NEG};

/// P-256 curve order (n) for scalar validation
const P256_ORDER: [u8; 32] = [
    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
    0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
];

/// Convert [u8; 32] to GenericArray for PrimeField
fn to_generic_array(bytes: &[u8; 32]) -> p256::FieldBytes {
    *p256::FieldBytes::from_slice(bytes)
}

/// Convert GenericArray to [u8; 32]
fn from_generic_array(arr: p256::FieldBytes) -> [u8; 32] {
    *arr.as_ref()
}

/// Decode SEC1 uncompressed point (65 bytes: 0x04 || x || y) to AffinePoint
fn decode_point(bytes: &[u8; 65]) -> CtOption<AffinePoint<NistP256>> {
    if bytes[0] != 0x04 {
        // Use ProjectivePoint identity and convert to AffinePoint
        let identity_proj = ProjectivePoint::<NistP256>::identity();
        let identity_affine = AffinePoint::<NistP256>::from(identity_proj);
        return CtOption::new(identity_affine, Choice::from(0));
    }

    let encoded = p256::EncodedPoint::from_bytes(bytes);
    let encoded = match encoded {
        Ok(ep) => ep,
        Err(_) => {
            let identity_proj = ProjectivePoint::<NistP256>::identity();
            let identity_affine = AffinePoint::<NistP256>::from(identity_proj);
            return CtOption::new(identity_affine, Choice::from(0));
        }
    };

    // Convert to affine point using FromEncodedPoint trait
    let affine = Option::from(AffinePoint::<NistP256>::from_encoded_point(&encoded));
    match affine {
        Some(point) => CtOption::new(point, Choice::from(1)),
        None => {
            let identity_proj = ProjectivePoint::<NistP256>::identity();
            let identity_affine = AffinePoint::<NistP256>::from(identity_proj);
            CtOption::new(identity_affine, Choice::from(0))
        }
    }
}

/// Encode AffinePoint to SEC1 uncompressed (65 bytes)
fn encode_point(point: &AffinePoint<NistP256>) -> [u8; 65] {
    let encoded = point.to_encoded_point(false); // uncompressed
    let mut out = [0u8; 65];
    out.copy_from_slice(encoded.as_bytes());
    out
}

/// Validate scalar is in [1, n-1]
pub fn validate_scalar(scalar: &[u8; 32]) -> bool {
    // Check non-zero
    let is_zero = scalar.iter().fold(Choice::from(1), |acc, &b| acc & Choice::from((b == 0) as u8));
    if is_zero.into() {
        return false;
    }

    // Check < order (constant-time comparison)
    let mut less = Choice::from(0);
    let mut equal_so_far = Choice::from(1);

    for i in 0..32 {
        let s = scalar[i];
        let o = P256_ORDER[i];

        let s_lt_o = Choice::from((s < o) as u8);
        let s_gt_o = Choice::from((s > o) as u8);

        less = less | (equal_so_far & s_lt_o);
        equal_so_far = equal_so_far & Choice::from((s == o) as u8) & !s_gt_o;
    }

    // Valid if less than order (and not zero, checked above)
    less.into()
}

/// SHA-256 hash
pub fn sha256(data: &[u8]) -> [u8; 32] {
    use sha2::{Sha256, Digest};
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().into()
}

/// Compute w = password(code) as scalar
pub fn compute_w_scalar(code: u32) -> [u8; 32] {
    let mut w = [0u8; 32];
    let value = code + 1;
    w[29] = ((value >> 16) & 0xFF) as u8;
    w[30] = ((value >> 8) & 0xFF) as u8;
    w[31] = (value & 0xFF) as u8;
    w
}

/// Convert 32-byte array to Scalar using from_repr
fn bytes_to_scalar(bytes: &[u8; 32]) -> CtOption<Scalar<NistP256>> {
    let field_bytes = to_generic_array(bytes);
    Scalar::<NistP256>::from_repr(field_bytes)
}

/// Compute our public share: X = w*M + x*G (phone) or Y = w*N + y*G (console)
pub fn compute_share(
    role_phone: bool,
    w: &[u8; 32],
    scalar: &[u8; 32],
    out: &mut [u8; 65],
) -> Result<(), ()> {
    // Convert to Scalar type for multiplication
    let w_scalar = bytes_to_scalar(w).into_option().ok_or(())?;
    let x_scalar = bytes_to_scalar(scalar).into_option().ok_or(())?;

    // Base point: M (phone) or N (console)
    let base_point = if role_phone { M_POINT } else { N_POINT };
    let base_affine = decode_point(&base_point).into_option().ok_or(())?;

    // Generator point G - use ProjectivePoint::generator()
    let generator = ProjectivePoint::<NistP256>::generator();

    // Compute w*M + x*G using projective arithmetic
    let base_proj: ProjectivePoint<NistP256> = base_affine.into();
    let gen_proj: ProjectivePoint<NistP256> = generator;

    let result_proj = base_proj * w_scalar + gen_proj * x_scalar;
    let result_affine = AffinePoint::<NistP256>::from(result_proj);

    out.copy_from_slice(&encode_point(&result_affine));
    Ok(())
}

/// Process peer's share and compute shared secret:
/// Phone: K = x*(B - w*N)
/// Console: K = y*(A - w*M)
pub fn process_their_point(
    role_phone: bool,
    their_point: &[u8; 65],
    w: &[u8; 32],
    scalar: &[u8; 32],
    out: &mut [u8; 65],
) -> Result<(), ()> {
    // Decode peer's point
    let their_affine = decode_point(their_point).into_option().ok_or(())?;

    // Convert to Scalar type for multiplication
    let w_scalar = bytes_to_scalar(w).into_option().ok_or(())?;
    let our_scalar = bytes_to_scalar(scalar).into_option().ok_or(())?;

    // Compute w*N (phone) or w*M (console)
    let neg_base_point = if role_phone { N_NEG } else { M_NEG }; // -N or -M
    let neg_base_affine = decode_point(&neg_base_point).into_option().ok_or(())?;

    // their_point - w*N = their_point + w*(-N) = their_point + (-w)*N
    // Actually we want: their_point + w * (-base)
    let neg_base_proj: ProjectivePoint<NistP256> = neg_base_affine.into();
    let their_proj: ProjectivePoint<NistP256> = their_affine.into();

    // Compute their_point + w * (-base)
    let w_times_neg_base = neg_base_proj * w_scalar;
    let diff = their_proj + w_times_neg_base;

    // Multiply by our scalar: K = scalar * (their_point - w*base)
    let result_proj = diff * our_scalar;
    let result_affine = AffinePoint::<NistP256>::from(result_proj);

    out.copy_from_slice(&encode_point(&result_affine));
    Ok(())
}

/// SPAKE2 context holder for operations
pub struct Spake2Context;

impl Spake2Context {
    pub fn validate_scalar(scalar: &[u8; 32]) -> bool {
        validate_scalar(scalar)
    }

    pub fn compute_share(
        role_phone: bool,
        w: &[u8; 32],
        scalar: &[u8; 32],
        out: &mut [u8; 65],
    ) -> Result<(), ()> {
        compute_share(role_phone, w, scalar, out)
    }

    pub fn process_their_point(
        role_phone: bool,
        their_point: &[u8; 65],
        w: &[u8; 32],
        scalar: &[u8; 32],
        out: &mut [u8; 65],
    ) -> Result<(), ()> {
        process_their_point(role_phone, their_point, w, scalar, out)
    }

    pub fn sha256(data: &[u8]) -> [u8; 32] {
        sha256(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::constants::{M_POINT, N_POINT};

    #[test]
    fn test_validate_scalar() {
        assert!(!validate_scalar(&[0u8; 32]));
        assert!(!validate_scalar(&P256_ORDER));
        let mut order_minus_1 = P256_ORDER;
        order_minus_1[31] = P256_ORDER[31].saturating_sub(1);
        assert!(validate_scalar(&order_minus_1));
        let mut small = [0u8; 32];
        small[31] = 1;
        assert!(validate_scalar(&small));
    }

    #[test]
    fn test_compute_share_phone() {
        let mut out = [0u8; 65];
        let w = compute_w_scalar(123456);
        let mut scalar = [0u8; 32];
        scalar[31] = 2;
        let result = compute_share(true, &w, &scalar, &mut out);
        assert!(result.is_ok());
    }

    #[test]
    fn test_compute_share_console() {
        let mut out = [0u8; 65];
        let w = compute_w_scalar(123456);
        let mut scalar = [0u8; 32];
        scalar[31] = 2;
        let result = compute_share(false, &w, &scalar, &mut out);
        assert!(result.is_ok());
    }
}