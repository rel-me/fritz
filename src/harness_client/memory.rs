//! Read-only macOS memory telemetry for the local chat supervisor.
use anyhow::{Context, Result, anyhow, ensure};
use std::{ffi::CStr, mem::MaybeUninit, time::Duration};

const NORMAL: u32 = 0x01; // DISPATCH_MEMORYPRESSURE_NORMAL
const SWAP_GROWTH_LIMIT: u64 = 128 * 1024 * 1024;
const SAMPLE_INTERVAL: Duration = Duration::from_millis(500);

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

    fn check(&self, lowest_swap: &mut u64) -> Result<()> {
        ensure!(
            self.level == NORMAL,
            "Fritz stopped local chat because macOS reported memory pressure. Wait for it to ease and try a smaller Context Budget in Settings → Harness."
        );
        *lowest_swap = (*lowest_swap).min(self.swap_used);
        ensure!(
            self.swap_used - *lowest_swap < SWAP_GROWTH_LIMIT,
            "Fritz stopped local chat because swap usage increased. Try a smaller Context Budget in Settings → Harness."
        );
        Ok(())
    }

    pub(super) async fn watch(initial: Option<Self>) -> anyhow::Error {
        let Some(initial) = initial else {
            return std::future::pending().await;
        };
        let mut lowest_swap = initial.swap_used;
        loop {
            tokio::time::sleep(SAMPLE_INTERVAL).await;
            if let Err(error) = Self::read().and_then(|sample| sample.check(&mut lowest_swap)) {
                return error;
            }
        }
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
    fn stable_existing_swap_allows_chat_but_pressure_or_new_swap_stops_it() {
        let existing_swap = 6 * 1024 * 1024 * 1024;
        let mut lowest = existing_swap;
        let sample = |level, swap_used| Sample { level, swap_used };

        assert!(sample(NORMAL, existing_swap).ensure_start().is_ok());
        assert!(sample(NORMAL, existing_swap).check(&mut lowest).is_ok());
        assert!(sample(2, existing_swap).ensure_start().is_err());
        assert!(sample(2, existing_swap).check(&mut lowest).is_err());

        let lower = existing_swap - SWAP_GROWTH_LIMIT;
        assert!(sample(NORMAL, lower).check(&mut lowest).is_ok());
        assert!(sample(NORMAL, existing_swap - 1).check(&mut lowest).is_ok());
        assert!(sample(NORMAL, existing_swap).check(&mut lowest).is_err());
    }
}
