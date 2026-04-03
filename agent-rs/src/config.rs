use std::fs;

#[derive(Debug, Clone)]
pub enum MgmtIface {
    Wlan0,
    Ethernet { iface: String },
}

#[derive(Debug, Clone)]
pub struct AgentConfig {
    pub box_id: String,
    pub backend_url: String,
    pub headscale_url: String,
    pub mgmt_iface: MgmtIface,
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("BOX_ID не задан или TEMPLATE: {path}")]
    BoxIdMissing { path: String },

    #[error("не удалось прочитать {path}: {source}")]
    FileRead { path: String, source: std::io::Error },

    #[error("backend URL не настроен")]
    BackendUrlMissing,

    #[error("headscale URL не настроен")]
    HeadscaleUrlMissing,
}

impl AgentConfig {
    pub fn load() -> Result<Self, ConfigError> {
        let box_id = read_file_trimmed("/etc/bridgebox/box-id")?;
        if box_id.is_empty() || box_id == "TEMPLATE" {
            return Err(ConfigError::BoxIdMissing {
                path: "/etc/bridgebox/box-id".into(),
            });
        }

        let backend_url = read_file_trimmed("/etc/bridgebox/backend-url")
            .or_else(|_| std::env::var("BACKEND_URL").map_err(|_| ConfigError::BackendUrlMissing))
            .map_err(|_| ConfigError::BackendUrlMissing)?;

        let headscale_url = read_file_trimmed("/etc/bridgebox/headscale-url")
            .or_else(|_| {
                std::env::var("HEADSCALE_URL").map_err(|_| ConfigError::HeadscaleUrlMissing)
            })
            .map_err(|_| ConfigError::HeadscaleUrlMissing)?;

        let mgmt_iface = match read_file_trimmed("/etc/bridgebox/mgmt-iface") {
            Ok(iface) if !iface.is_empty() => MgmtIface::Ethernet { iface },
            _ => MgmtIface::Wlan0,
        };

        Ok(AgentConfig {
            box_id,
            backend_url,
            headscale_url,
            mgmt_iface,
        })
    }
}

fn read_file_trimmed(path: &str) -> Result<String, ConfigError> {
    fs::read_to_string(path)
        .map(|s| s.trim().to_string())
        .map_err(|e| ConfigError::FileRead {
            path: path.into(),
            source: e,
        })
}
