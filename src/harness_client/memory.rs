//! Read-only macOS memory telemetry for the local chat supervisor.
use anyhow::{Context, Result, anyhow, ensure};
use std::{
    ffi::CStr,
    mem::MaybeUninit,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

const NORMAL: u32 = 0x01; // DISPATCH_MEMORYPRESSURE_NORMAL
const WARNING: u32 = 0x02; // DISPATCH_MEMORYPRESSURE_WARN
const SWAP_GROWTH_LIMIT: u64 = 128 * 1024 * 1024;
const SAMPLE_INTERVAL: Duration = Duration::from_millis(500);
const STARTUP_WARNING_LIMIT: Duration = Duration::from_secs(1);
const PRESSURE_ERROR: &str = "Fritz stopped local chat because macOS reported memory pressure. Wait for it to ease and try a smaller Context Budget in Settings → Harness.";

pub(super) struct Sample {
    level: u32,
    swap_used: u64,
}

impl Sample {
    pub(super) fn read() -> Result<Self> {
        Ok(Self {
            // XNU exports the current pressure as dispatch memory-pressure flags.
            level: read_sysctl(c"kern.memorystatus_vm_pressure_level")
                .context("Could not read macOS memory pressure for local chat")?,
            swap_used: read_sysctl::<libc::xsw_usage>(c"vm.swapusage")
                .context("Could not read macOS swap usage for local chat")?
                .xsu_used,
        })
    }

    pub(super) fn ensure_start(&self) -> Result<()> {
        ensure!(
            self.level == NORMAL,
            "Fritz paused local chat because macOS is under memory pressure. Close other memory-intensive apps or wait for memory pressure to ease, then retry."
        );
        Ok(())
    }

    pub(super) async fn watch(initial: Option<Self>, starting: &AtomicBool) -> anyhow::Error {
        let Some(initial) = initial else {
            return std::future::pending().await;
        };
        let mut guard = Guard::new(initial.swap_used);
        loop {
            tokio::time::sleep(SAMPLE_INTERVAL).await;
            if let Err(error) = Self::read().and_then(|sample| {
                guard.check(sample, starting.load(Ordering::Relaxed), Instant::now())
            }) {
                return error;
            }
        }
    }
}

struct Guard {
    lowest_swap: u64,
    warning_since: Option<Instant>,
}

impl Guard {
    fn new(initial_swap: u64) -> Self {
        Self {
            lowest_swap: initial_swap,
            warning_since: None,
        }
    }

    fn check(&mut self, sample: Sample, starting: bool, now: Instant) -> Result<()> {
        ensure!(
            sample.level == NORMAL || (starting && sample.level == WARNING),
            "{PRESSURE_ERROR}"
        );
        self.lowest_swap = self.lowest_swap.min(sample.swap_used);
        ensure!(
            sample.swap_used - self.lowest_swap < SWAP_GROWTH_LIMIT,
            "Fritz stopped local chat because swap usage increased. Try a smaller Context Budget in Settings → Harness."
        );
        if sample.level == WARNING {
            let since = *self.warning_since.get_or_insert(now);
            ensure!(
                now.duration_since(since) < STARTUP_WARNING_LIMIT,
                "{PRESSURE_ERROR}"
            );
        } else {
            self.warning_since = None;
        }
        Ok(())
    }
}

// Callers only use integer types or the matching C layout for the named sysctl.
fn read_sysctl<T: Copy>(name: &CStr) -> std::io::Result<T> {
    let mut value = MaybeUninit::<T>::uninit();
    let mut len = size_of::<T>();
    // SAFETY: sysctl writes at most len bytes to the provided buffer.
    let status = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            value.as_mut_ptr().cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return Err(std::io::Error::last_os_error());
    }
    if len != size_of::<T>() {
        return Err(std::io::Error::other(anyhow!(
            "Unexpected size for {name:?}"
        )));
    }
    // SAFETY: the kernel wrote the entire matching C value on success.
    Ok(unsafe { value.assume_init() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_only_tolerates_brief_warnings_without_swap_growth() {
        let existing_swap = 6 * 1024 * 1024 * 1024;
        let sample = |level, swap_used| Sample { level, swap_used };
        let now = Instant::now();

        assert!(sample(NORMAL, existing_swap).ensure_start().is_ok());
        assert!(sample(WARNING, existing_swap).ensure_start().is_err());
        let mut guard = Guard::new(existing_swap);
        for (elapsed_ms, level) in [
            (0, WARNING),
            (500, WARNING),
            (1000, NORMAL),
            (1500, WARNING),
            (2000, WARNING),
        ] {
            assert!(
                guard
                    .check(
                        sample(level, existing_swap),
                        true,
                        now + Duration::from_millis(elapsed_ms)
                    )
                    .is_ok()
            );
        }
        assert!(
            guard
                .check(
                    sample(WARNING, existing_swap),
                    true,
                    now + Duration::from_millis(2500)
                )
                .is_err()
        );

        let mut guard = Guard::new(existing_swap);
        assert!(guard.check(sample(0x04, existing_swap), true, now).is_err());
        assert!(
            guard
                .check(sample(WARNING, existing_swap), false, now)
                .is_err()
        );

        let lower = existing_swap - SWAP_GROWTH_LIMIT;
        assert!(guard.check(sample(NORMAL, lower), true, now).is_ok());
        assert!(
            guard
                .check(sample(WARNING, existing_swap - 1), true, now)
                .is_ok()
        );
        let error = guard
            .check(sample(WARNING, existing_swap), true, now)
            .unwrap_err();
        assert!(error.to_string().contains("swap usage increased"));
    }
}
