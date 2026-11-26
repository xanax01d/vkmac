uniffi::setup_scaffolding!();

pub mod api;
pub mod auth;
pub mod client;
pub mod config;
pub mod error;
pub mod keychain;
pub mod longpoll;
pub mod models;
pub mod storage;

pub use client::VkClient;
