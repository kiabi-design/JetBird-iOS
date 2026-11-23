//! Transcript building for SPAKE2 key confirmation

/// Write a byte slice prefixed with its length as 8-byte big-endian
pub fn write_prefixed(buf: &mut alloc::vec::Vec<u8>, data: &[u8]) {
    let len = data.len() as u64;
    buf.extend_from_slice(&len.to_be_bytes());
    buf.extend_from_slice(data);
}

/// Write a fixed-size array prefixed with its length
pub fn write_prefixed_array<const N: usize>(buf: &mut alloc::vec::Vec<u8>, data: &[u8; N]) {
    write_prefixed(buf, data);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_write_prefixed() {
        let mut buf = alloc::vec::Vec::new();
        write_prefixed(&mut buf, b"hello");
        assert_eq!(buf.len(), 8 + 5);
        assert_eq!(&buf[0..8], &5u64.to_be_bytes());
        assert_eq!(&buf[8..], b"hello");
    }
}