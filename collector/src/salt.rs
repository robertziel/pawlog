use std::io::Read;
use std::sync::Mutex;

pub const DAY_MS: i64 = 86_400_000;

/// Random per-UTC-day salt, kept only in memory: once the day rolls over, yesterday's hashes can't be recomputed.
pub struct DailySalt(Mutex<(i64, [u8; 32])>);

impl Default for DailySalt {
    fn default() -> Self {
        Self(Mutex::new((i64::MIN, [0; 32])))
    }
}

impl DailySalt {
    pub fn get(&self, now_ms: i64) -> [u8; 32] {
        let day = now_ms.div_euclid(DAY_MS);
        let mut g = self.0.lock().unwrap();
        if g.0 != day {
            *g = (day, random32());
        }
        g.1
    }
}

fn random32() -> [u8; 32] {
    let mut b = [0; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut b))
        .expect("read /dev/urandom");
    b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotates_at_utc_midnight_only() {
        let s = DailySalt::default();
        let day = 20_000 * DAY_MS;
        let a = s.get(day);
        assert_eq!(a, s.get(day + DAY_MS - 1));
        assert_ne!(a, s.get(day + DAY_MS));
    }
}
