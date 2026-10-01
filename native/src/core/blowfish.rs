//! Decrypt-only Blowfish (Bruce Schneier, 1993; public domain), the cipher of the pk2 directory
//! table. A port of client/scripts/pk2/blowfish.gd; docs/protocol/PK2_FORMAT.md has the format.

use super::blowfish_constants::{P_INIT, S0, S1, S2, S3};

pub struct Blowfish {
    p: [u32; 18],
    s: [[u32; 256]; 4],
}

impl Blowfish {
    /// The standard key schedule. Panics on an empty key, as blowfish.gd asserts.
    pub fn new(key: &[u8]) -> Blowfish {
        assert!(!key.is_empty(), "Blowfish key must not be empty");
        let mut bf = Blowfish { p: P_INIT, s: [S0, S1, S2, S3] };
        let mut j = 0usize;
        for i in 0..18 {
            let mut d: u32 = 0;
            for _ in 0..4 {
                d = (d << 8) | key[j] as u32;
                j = (j + 1) % key.len();
            }
            bf.p[i] ^= d;
        }
        let (mut l, mut r) = (0u32, 0u32);
        for i in (0..18).step_by(2) {
            (l, r) = bf.encrypt(l, r);
            bf.p[i] = l;
            bf.p[i + 1] = r;
        }
        for b in 0..4 {
            for i in (0..256).step_by(2) {
                (l, r) = bf.encrypt(l, r);
                bf.s[b][i] = l;
                bf.s[b][i + 1] = r;
            }
        }
        bf
    }

    #[inline(always)]
    fn f(&self, x: u32) -> u32 {
        let a = self.s[0][(x >> 24) as usize];
        let b = self.s[1][((x >> 16) & 0xff) as usize];
        let c = self.s[2][((x >> 8) & 0xff) as usize];
        let d = self.s[3][(x & 0xff) as usize];
        (a.wrapping_add(b) ^ c).wrapping_add(d)
    }

    /// Encryption: the key schedule's own step, and how synthetic test archives are built.
    pub fn encrypt(&self, mut l: u32, mut r: u32) -> (u32, u32) {
        for i in (0..16).step_by(2) {
            l ^= self.p[i];
            r ^= self.f(l);
            r ^= self.p[i + 1];
            l ^= self.f(r);
        }
        l ^= self.p[16];
        r ^= self.p[17];
        (r, l)
    }

    #[inline]
    pub fn decrypt(&self, mut l: u32, mut r: u32) -> (u32, u32) {
        let mut i = 17;
        while i > 1 {
            l ^= self.p[i];
            r ^= self.f(l);
            r ^= self.p[i - 1];
            l ^= self.f(r);
            i -= 2;
        }
        l ^= self.p[1];
        r ^= self.p[0];
        (r, l)
    }

    /// One standard (big-endian) 8-byte ECB block, as blowfish.gd's decrypt_block.
    pub fn decrypt_block_be(&self, block: &mut [u8]) {
        let l = u32::from_be_bytes([block[0], block[1], block[2], block[3]]);
        let r = u32::from_be_bytes([block[4], block[5], block[6], block[7]]);
        let (l, r) = self.decrypt(l, r);
        block[0..4].copy_from_slice(&l.to_be_bytes());
        block[4..8].copy_from_slice(&r.to_be_bytes());
    }

    /// The pk2 directory variant (pk2_reader.gd's _decrypt_block_pk2): each 4-byte half of every
    /// 8-byte block is byte-reversed before a standard decrypt and reversed back after -- i.e.
    /// each half is a little-endian word. A trailing partial block is left as it is.
    pub fn decrypt_pk2_in_place(&self, data: &mut [u8]) {
        for chunk in data.chunks_exact_mut(8) {
            let l = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            let r = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
            let (l, r) = self.decrypt(l, r);
            chunk[0..4].copy_from_slice(&l.to_le_bytes());
            chunk[4..8].copy_from_slice(&r.to_le_bytes());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    /// Schneier's published variable-key test vectors (the same ones blowfish_test.gd checks).
    #[test]
    fn known_answers() {
        let vectors = [
            ("0000000000000000", "0000000000000000", "4EF997456198DD78"),
            ("FFFFFFFFFFFFFFFF", "FFFFFFFFFFFFFFFF", "51866FD5B85ECB8A"),
            ("3000000000000000", "1000000000000001", "7D856F9A613063F2"),
            ("1111111111111111", "1111111111111111", "2466DD878B963C9D"),
            ("0123456789ABCDEF", "1111111111111111", "61F9C3802281B096"),
            ("FEDCBA9876543210", "0123456789ABCDEF", "0ACEAB0FC6A0A28D"),
            ("7CA110454A1A6E57", "01A1D6D039776742", "59C68245EB05282B"),
            ("0131D9619DC1376E", "5CD54CA83DEF57DA", "B1B8CC0B250F09A0"),
            ("169841", "48656C6C6F217878", "3422C5F34A212581"),
        ];
        for (key, plain, cipher) in vectors {
            let bf = Blowfish::new(&hex(key));
            let mut block = hex(cipher);
            bf.decrypt_block_be(&mut block);
            assert_eq!(block, hex(plain), "key {key}");
        }
    }

    #[test]
    fn pk2_variant_is_the_byte_swapped_standard() {
        let bf = Blowfish::new(b"\x32\xce\xdd\x7c\xbc\xa8");
        let mut a: Vec<u8> = (0u8..16).collect();
        let mut b = a.clone();
        bf.decrypt_pk2_in_place(&mut a);
        for c in b.chunks_exact_mut(8) {
            c[0..4].reverse();
            c[4..8].reverse();
            bf.decrypt_block_be(c);
            c[0..4].reverse();
            c[4..8].reverse();
        }
        assert_eq!(a, b);
    }
}
