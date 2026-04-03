use super::StateMachine;

pub const MAX_APPLY_ATTEMPTS: u8 = 3;
pub const BUNDLE_ARCHIVE: &str = "/opt/bridgebox/bundle.tar.gz";
pub const BUNDLE_DIR: &str = "/opt/bridgebox/bundle";

#[derive(Debug, Clone, PartialEq)]
pub enum OverlayState {
    None,
    Downloading {
        version: String,
        url: String,
        sha256: String,
    },
    Applying {
        version: String,
        attempt: u8,
    },
    Applied {
        version: String,
    },
    Failed {
        version: String,
        reason: String,
        attempt: u8,
    },
    RollingBack {
        from_version: String,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum OverlayEvent {
    Apply {
        version: String,
        url: String,
        sha256: String,
    },
    DownloadOk,
    DownloadFailed {
        reason: String,
    },
    Sha256Mismatch {
        expected: String,
        actual: String,
    },
    ApplyOk,
    ApplyFailed {
        reason: String,
    },
    Remove,
    RollbackComplete,
}

#[derive(Debug, Clone, PartialEq)]
pub enum OverlayEffect {
    Download { url: String, dest: String },
    Extract { archive: String, dest: String },
    RunApply { bundle_dir: String },
    RunRollback { bundle_dir: String },
    WriteVersion { version: Option<String>, status: String },
    CleanupArchive { path: String },
    Notify(OverlayNotification),
}

#[derive(Debug, Clone, PartialEq)]
pub enum OverlayNotification {
    Applied { version: String },
    Failed { version: String, reason: String, attempt: u8 },
    RolledBack,
}

impl StateMachine for OverlayState {
    type Event = OverlayEvent;
    type Effect = OverlayEffect;

    fn handle(self, event: Self::Event) -> (Self, Vec<Self::Effect>) {
        match (self, event) {
            // None/Applied/Failed + Apply → Downloading + Download
            (OverlayState::None, OverlayEvent::Apply { version, url, sha256 })
            | (OverlayState::Applied { .. }, OverlayEvent::Apply { version, url, sha256 })
            | (OverlayState::Failed { .. }, OverlayEvent::Apply { version, url, sha256 }) => {
                let effects = vec![OverlayEffect::Download {
                    url: url.clone(),
                    dest: BUNDLE_ARCHIVE.to_string(),
                }];
                let state = OverlayState::Downloading { version, url, sha256 };
                (state, effects)
            }

            // Downloading + DownloadOk → Applying{attempt=1} + Extract, CleanupArchive, RunApply
            (OverlayState::Downloading { version, .. }, OverlayEvent::DownloadOk) => {
                let effects = vec![
                    OverlayEffect::Extract {
                        archive: BUNDLE_ARCHIVE.to_string(),
                        dest: BUNDLE_DIR.to_string(),
                    },
                    OverlayEffect::CleanupArchive {
                        path: BUNDLE_ARCHIVE.to_string(),
                    },
                    OverlayEffect::RunApply {
                        bundle_dir: BUNDLE_DIR.to_string(),
                    },
                ];
                let state = OverlayState::Applying { version, attempt: 1 };
                (state, effects)
            }

            // Downloading + DownloadFailed → Failed + WriteVersion, Notify(Failed)
            (OverlayState::Downloading { version, .. }, OverlayEvent::DownloadFailed { reason }) => {
                let effects = vec![
                    OverlayEffect::WriteVersion {
                        version: Some(version.clone()),
                        status: "failed".to_string(),
                    },
                    OverlayEffect::Notify(OverlayNotification::Failed {
                        version: version.clone(),
                        reason: reason.clone(),
                        attempt: 0,
                    }),
                ];
                let state = OverlayState::Failed { version, reason, attempt: 0 };
                (state, effects)
            }

            // Downloading + Sha256Mismatch → Failed + CleanupArchive, WriteVersion, Notify(Failed)
            (OverlayState::Downloading { version, .. }, OverlayEvent::Sha256Mismatch { expected, actual }) => {
                let reason = format!("sha256 mismatch: expected {}, got {}", expected, actual);
                let effects = vec![
                    OverlayEffect::CleanupArchive {
                        path: BUNDLE_ARCHIVE.to_string(),
                    },
                    OverlayEffect::WriteVersion {
                        version: Some(version.clone()),
                        status: "failed".to_string(),
                    },
                    OverlayEffect::Notify(OverlayNotification::Failed {
                        version: version.clone(),
                        reason: reason.clone(),
                        attempt: 0,
                    }),
                ];
                let state = OverlayState::Failed { version, reason, attempt: 0 };
                (state, effects)
            }

            // Applying + ApplyOk → Applied + WriteVersion, Notify(Applied)
            (OverlayState::Applying { version, .. }, OverlayEvent::ApplyOk) => {
                let effects = vec![
                    OverlayEffect::WriteVersion {
                        version: Some(version.clone()),
                        status: "applied".to_string(),
                    },
                    OverlayEffect::Notify(OverlayNotification::Applied {
                        version: version.clone(),
                    }),
                ];
                let state = OverlayState::Applied { version };
                (state, effects)
            }

            // Applying + ApplyFailed (attempt < MAX) → Failed + Notify(Failed)
            (OverlayState::Applying { version, attempt }, OverlayEvent::ApplyFailed { reason })
                if attempt < MAX_APPLY_ATTEMPTS =>
            {
                let effects = vec![
                    OverlayEffect::Notify(OverlayNotification::Failed {
                        version: version.clone(),
                        reason: reason.clone(),
                        attempt,
                    }),
                ];
                let state = OverlayState::Failed { version, reason, attempt };
                (state, effects)
            }

            // Applying + ApplyFailed (attempt >= MAX) → Failed + WriteVersion, Notify(Failed)
            (OverlayState::Applying { version, attempt }, OverlayEvent::ApplyFailed { reason }) => {
                let effects = vec![
                    OverlayEffect::WriteVersion {
                        version: Some(version.clone()),
                        status: "failed".to_string(),
                    },
                    OverlayEffect::Notify(OverlayNotification::Failed {
                        version: version.clone(),
                        reason: reason.clone(),
                        attempt,
                    }),
                ];
                let state = OverlayState::Failed { version, reason, attempt };
                (state, effects)
            }

            // Applied + Remove → RollingBack + RunRollback
            (OverlayState::Applied { version }, OverlayEvent::Remove) => {
                let effects = vec![OverlayEffect::RunRollback {
                    bundle_dir: BUNDLE_DIR.to_string(),
                }];
                let state = OverlayState::RollingBack { from_version: version };
                (state, effects)
            }

            // RollingBack + RollbackComplete → None + WriteVersion, Notify(RolledBack)
            (OverlayState::RollingBack { .. }, OverlayEvent::RollbackComplete) => {
                let effects = vec![
                    OverlayEffect::WriteVersion {
                        version: None,
                        status: "none".to_string(),
                    },
                    OverlayEffect::Notify(OverlayNotification::RolledBack),
                ];
                (OverlayState::None, effects)
            }

            // All other → (state, vec![])
            (state, _) => (state, vec![]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn none_apply_starts_downloading() {
        let (state, effects) = OverlayState::None.handle(OverlayEvent::Apply {
            version: "1.0".to_string(),
            url: "https://example.com/bundle.tar.gz".to_string(),
            sha256: "abc123".to_string(),
        });
        assert_eq!(
            state,
            OverlayState::Downloading {
                version: "1.0".to_string(),
                url: "https://example.com/bundle.tar.gz".to_string(),
                sha256: "abc123".to_string(),
            }
        );
        assert_eq!(effects.len(), 1);
        assert_eq!(
            effects[0],
            OverlayEffect::Download {
                url: "https://example.com/bundle.tar.gz".to_string(),
                dest: BUNDLE_ARCHIVE.to_string(),
            }
        );
    }

    #[test]
    fn downloading_ok_starts_applying() {
        let state = OverlayState::Downloading {
            version: "1.0".to_string(),
            url: "https://example.com/bundle.tar.gz".to_string(),
            sha256: "abc123".to_string(),
        };
        let (state, effects) = state.handle(OverlayEvent::DownloadOk);
        assert_eq!(
            state,
            OverlayState::Applying {
                version: "1.0".to_string(),
                attempt: 1,
            }
        );
        assert_eq!(effects.len(), 3);
        assert_eq!(
            effects[0],
            OverlayEffect::Extract {
                archive: BUNDLE_ARCHIVE.to_string(),
                dest: BUNDLE_DIR.to_string(),
            }
        );
        assert_eq!(
            effects[1],
            OverlayEffect::CleanupArchive {
                path: BUNDLE_ARCHIVE.to_string(),
            }
        );
        assert_eq!(
            effects[2],
            OverlayEffect::RunApply {
                bundle_dir: BUNDLE_DIR.to_string(),
            }
        );
    }

    #[test]
    fn applying_ok_becomes_applied() {
        let state = OverlayState::Applying {
            version: "1.0".to_string(),
            attempt: 1,
        };
        let (state, effects) = state.handle(OverlayEvent::ApplyOk);
        assert_eq!(
            state,
            OverlayState::Applied {
                version: "1.0".to_string(),
            }
        );
        assert_eq!(effects.len(), 2);
        assert_eq!(
            effects[0],
            OverlayEffect::WriteVersion {
                version: Some("1.0".to_string()),
                status: "applied".to_string(),
            }
        );
        assert_eq!(
            effects[1],
            OverlayEffect::Notify(OverlayNotification::Applied {
                version: "1.0".to_string(),
            })
        );
    }

    #[test]
    fn applying_failed_under_max_allows_retry() {
        let state = OverlayState::Applying {
            version: "1.0".to_string(),
            attempt: 1,
        };
        let (state, effects) = state.handle(OverlayEvent::ApplyFailed {
            reason: "script error".to_string(),
        });
        assert_eq!(
            state,
            OverlayState::Failed {
                version: "1.0".to_string(),
                reason: "script error".to_string(),
                attempt: 1,
            }
        );
        assert_eq!(effects.len(), 1);
        assert_eq!(
            effects[0],
            OverlayEffect::Notify(OverlayNotification::Failed {
                version: "1.0".to_string(),
                reason: "script error".to_string(),
                attempt: 1,
            })
        );
    }

    #[test]
    fn applying_failed_at_max_is_final() {
        let state = OverlayState::Applying {
            version: "1.0".to_string(),
            attempt: 3,
        };
        let (state, effects) = state.handle(OverlayEvent::ApplyFailed {
            reason: "script error".to_string(),
        });
        assert_eq!(
            state,
            OverlayState::Failed {
                version: "1.0".to_string(),
                reason: "script error".to_string(),
                attempt: 3,
            }
        );
        assert_eq!(effects.len(), 2);
        assert_eq!(
            effects[0],
            OverlayEffect::WriteVersion {
                version: Some("1.0".to_string()),
                status: "failed".to_string(),
            }
        );
        assert_eq!(
            effects[1],
            OverlayEffect::Notify(OverlayNotification::Failed {
                version: "1.0".to_string(),
                reason: "script error".to_string(),
                attempt: 3,
            })
        );
    }

    #[test]
    fn applied_remove_starts_rollback() {
        let state = OverlayState::Applied {
            version: "1.0".to_string(),
        };
        let (state, effects) = state.handle(OverlayEvent::Remove);
        assert_eq!(
            state,
            OverlayState::RollingBack {
                from_version: "1.0".to_string(),
            }
        );
        assert_eq!(effects.len(), 1);
        assert_eq!(
            effects[0],
            OverlayEffect::RunRollback {
                bundle_dir: BUNDLE_DIR.to_string(),
            }
        );
    }

    #[test]
    fn rollback_complete_becomes_none() {
        let state = OverlayState::RollingBack {
            from_version: "1.0".to_string(),
        };
        let (state, effects) = state.handle(OverlayEvent::RollbackComplete);
        assert_eq!(state, OverlayState::None);
        assert_eq!(effects.len(), 2);
        assert_eq!(
            effects[0],
            OverlayEffect::WriteVersion {
                version: None,
                status: "none".to_string(),
            }
        );
        assert_eq!(effects[1], OverlayEffect::Notify(OverlayNotification::RolledBack));
    }

    #[test]
    fn sha256_mismatch_fails() {
        let state = OverlayState::Downloading {
            version: "1.0".to_string(),
            url: "https://example.com/bundle.tar.gz".to_string(),
            sha256: "expected_hash".to_string(),
        };
        let (state, effects) = state.handle(OverlayEvent::Sha256Mismatch {
            expected: "expected_hash".to_string(),
            actual: "actual_hash".to_string(),
        });
        assert_eq!(
            state,
            OverlayState::Failed {
                version: "1.0".to_string(),
                reason: "sha256 mismatch: expected expected_hash, got actual_hash".to_string(),
                attempt: 0,
            }
        );
        assert_eq!(effects.len(), 3);
        assert_eq!(
            effects[0],
            OverlayEffect::CleanupArchive {
                path: BUNDLE_ARCHIVE.to_string(),
            }
        );
        assert_eq!(
            effects[1],
            OverlayEffect::WriteVersion {
                version: Some("1.0".to_string()),
                status: "failed".to_string(),
            }
        );
        assert_eq!(
            effects[2],
            OverlayEffect::Notify(OverlayNotification::Failed {
                version: "1.0".to_string(),
                reason: "sha256 mismatch: expected expected_hash, got actual_hash".to_string(),
                attempt: 0,
            })
        );
    }
}
