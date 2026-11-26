use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use rusqlite::{params, Connection, ErrorCode, OptionalExtension, TransactionBehavior};

use crate::error::VkError;
use crate::models::{
    AccountSummary, ArtistStat, Attachment, AudioTrack, ChatStats, ConversationItem, MessageItem,
    SnippetItem, UserProfile,
};

pub struct Storage {
    conn: Mutex<Connection>,
    db_path: Option<PathBuf>,
}

impl Storage {
    pub fn open(data_dir: &Path) -> Result<Self, VkError> {
        std::fs::create_dir_all(data_dir).map_err(|err| VkError::Storage {
            details: format!(
                "Failed to create storage directory {}: {err}",
                data_dir.display()
            ),
        })?;

        let db_path = data_dir.join("cache.db");
        let mut conn = Connection::open(&db_path)?;
        conn.busy_timeout(Duration::from_millis(5000))?;
        enable_wal_with_retry(&conn, Duration::from_millis(5000))?;
        conn.execute_batch(
            "
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            ",
        )?;
        migrate(&mut conn)?;

        Ok(Self {
            conn: Mutex::new(conn),
            db_path: Some(db_path),
        })
    }

    pub fn in_memory() -> Result<Self, VkError> {
        let mut conn = Connection::open_in_memory()?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        migrate(&mut conn)?;

        Ok(Self {
            conn: Mutex::new(conn),
            db_path: None,
        })
    }

    pub fn db_path(&self) -> Option<&Path> {
        self.db_path.as_deref()
    }

    pub fn schema_version(&self) -> Result<i64, VkError> {
        let conn = self.lock_conn()?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        Ok(version)
    }

    fn lock_conn(&self) -> Result<std::sync::MutexGuard<'_, Connection>, VkError> {
        self.conn.lock().map_err(|_| VkError::Storage {
            details: "Storage mutex poisoned".to_string(),
        })
    }

    pub fn upsert_users(&self, users: &[UserProfile], updated_at: i64) -> Result<(), VkError> {
        if users.is_empty() {
            return Ok(());
        }

        let mut conn = self.lock_conn()?;
        let tx = conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "
                INSERT INTO users (id, first_name, last_name, avatar_url, online, updated_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                ON CONFLICT(id) DO UPDATE SET
                    first_name = excluded.first_name,
                    last_name  = excluded.last_name,
                    avatar_url = excluded.avatar_url,
                    online     = excluded.online,
                    updated_at = excluded.updated_at
                ",
            )?;

            for user in users {
                stmt.execute(params![
                    user.id,
                    user.first_name,
                    user.last_name,
                    user.avatar_url,
                    i64::from(user.online),
                    updated_at,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn get_user(&self, user_id: i64) -> Result<Option<UserProfile>, VkError> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare_cached(
            "SELECT id, first_name, last_name, avatar_url, online FROM users WHERE id = ?1",
        )?;

        let user = stmt
            .query_row(params![user_id], |row| {
                let online_int: i64 = row.get(4)?;
                Ok(UserProfile {
                    id: row.get(0)?,
                    first_name: row.get(1)?,
                    last_name: row.get(2)?,
                    avatar_url: row.get(3)?,
                    online: online_int != 0,
                })
            })
            .optional()?;

        Ok(user)
    }

    pub fn upsert_conversations(&self, conversations: &[ConversationItem]) -> Result<(), VkError> {
        if conversations.is_empty() {
            return Ok(());
        }

        let mut conn = self.lock_conn()?;
        let tx = conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "
                INSERT INTO conversations (
                    peer_id, title, avatar_url, last_msg_text, last_msg_date,
                    unread_count, is_muted, raw_json
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                ON CONFLICT(peer_id) DO UPDATE SET
                    title         = excluded.title,
                    avatar_url    = excluded.avatar_url,
                    last_msg_text = excluded.last_msg_text,
                    last_msg_date = excluded.last_msg_date,
                    unread_count  = excluded.unread_count,
                    is_muted      = excluded.is_muted,
                    raw_json      = excluded.raw_json
                ",
            )?;

            for conv in conversations {
                let raw_json = serde_json::to_string(conv).map_err(|err| VkError::Storage {
                    details: format!("Failed to serialize conversation: {err}"),
                })?;
                stmt.execute(params![
                    conv.peer_id,
                    conv.title,
                    conv.avatar_url,
                    conv.last_message_text,
                    conv.last_message_date,
                    i64::from(conv.unread_count),
                    i64::from(conv.is_muted),
                    raw_json,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn get_conversations(
        &self,
        offset: u32,
        count: u32,
    ) -> Result<Vec<ConversationItem>, VkError> {
        if count == 0 {
            return Ok(Vec::new());
        }

        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare_cached(
            "
            SELECT peer_id, title, avatar_url, last_msg_text, last_msg_date, unread_count, is_muted
            FROM conversations
            ORDER BY last_msg_date DESC, peer_id DESC
            LIMIT ?1 OFFSET ?2
            ",
        )?;

        let rows = stmt.query_map(params![i64::from(count), i64::from(offset)], |row| {
            let unread_i64: i64 = row.get(5)?;
            let is_muted_i64: i64 = row.get(6)?;
            Ok(ConversationItem {
                peer_id: row.get(0)?,
                title: row.get(1)?,
                avatar_url: row.get(2)?,
                last_message_text: row.get(3)?,
                last_message_date: row.get(4)?,
                unread_count: u32::try_from(unread_i64.max(0)).unwrap_or(u32::MAX),
                is_muted: is_muted_i64 != 0,
            })
        })?;

        let mut result = Vec::new();
        for item in rows {
            result.push(item?);
        }
        Ok(result)
    }

    pub fn update_conversation_on_new_message(&self, msg: &MessageItem) -> Result<(), VkError> {
        let preview = message_preview_text(msg);
        let conn = self.lock_conn()?;
        conn.execute(
            "
            UPDATE conversations
            SET last_msg_text = ?2,
                last_msg_date = ?3,
                unread_count = CASE WHEN ?4 = 1 THEN 0 ELSE unread_count + 1 END
            WHERE peer_id = ?1 AND last_msg_date <= ?3
            ",
            params![msg.peer_id, preview, msg.date, i64::from(msg.is_out)],
        )?;
        Ok(())
    }

    pub fn mark_conversation_read(&self, peer_id: i64) -> Result<(), VkError> {
        let conn = self.lock_conn()?;
        conn.execute(
            "UPDATE conversations SET unread_count = 0 WHERE peer_id = ?1",
            params![peer_id],
        )?;
        Ok(())
    }

    pub fn upsert_messages(&self, messages: &[MessageItem]) -> Result<(), VkError> {
        if messages.is_empty() {
            return Ok(());
        }

        let mut conn = self.lock_conn()?;
        let tx = conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "
                INSERT INTO messages (id, peer_id, from_id, text, date, is_out, raw_json)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT(id) DO UPDATE SET
                    peer_id  = excluded.peer_id,
                    from_id  = excluded.from_id,
                    text     = excluded.text,
                    date     = excluded.date,
                    is_out   = excluded.is_out,
                    raw_json = excluded.raw_json
                ",
            )?;

            for msg in messages {
                let raw_json =
                    serde_json::to_string(&msg.attachments).map_err(|err| VkError::Storage {
                        details: format!("Failed to serialize message attachments: {err}"),
                    })?;
                stmt.execute(params![
                    msg.id,
                    msg.peer_id,
                    msg.from_id,
                    msg.text,
                    msg.date,
                    i64::from(msg.is_out),
                    raw_json,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn get_messages(
        &self,
        peer_id: i64,
        offset: u32,
        count: u32,
    ) -> Result<Vec<MessageItem>, VkError> {
        if count == 0 {
            return Ok(Vec::new());
        }

        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare_cached(
            "
            SELECT id, peer_id, from_id, text, date, is_out, raw_json
            FROM messages
            WHERE peer_id = ?1
            ORDER BY date DESC, id DESC
            LIMIT ?2 OFFSET ?3
            ",
        )?;

        let mut rows = stmt.query(params![peer_id, i64::from(count), i64::from(offset)])?;
        let mut result = Vec::new();

        while let Some(row) = rows.next()? {
            let is_out_i64: i64 = row.get(5)?;
            let raw_json: String = row.get(6)?;
            let attachments = decode_attachments(&raw_json)?;
            result.push(MessageItem {
                id: row.get(0)?,
                peer_id: row.get(1)?,
                from_id: row.get(2)?,
                text: row.get(3)?,
                date: row.get(4)?,
                is_out: is_out_i64 != 0,
                attachments,
            });
        }

        Ok(result)
    }

    pub fn upsert_audio_tracks(
        &self,
        tracks: &[AudioTrack],
        start_position: u32,
    ) -> Result<(), VkError> {
        if tracks.is_empty() {
            return Ok(());
        }

        let mut conn = self.lock_conn()?;
        let tx = conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "
                INSERT INTO audio_tracks (
                    id, owner_id, artist, title, duration, stream_url, cover_url, position
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                ON CONFLICT(owner_id, id) DO UPDATE SET
                    artist     = excluded.artist,
                    title      = excluded.title,
                    duration   = excluded.duration,
                    stream_url = excluded.stream_url,
                    cover_url  = excluded.cover_url,
                    position   = excluded.position
                ",
            )?;

            for (idx, track) in tracks.iter().enumerate() {
                let position = i64::from(start_position) + idx as i64;
                stmt.execute(params![
                    track.id,
                    track.owner_id,
                    track.artist,
                    track.title,
                    i64::from(track.duration_sec),
                    track.stream_url,
                    track.cover_url,
                    position,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn get_audio_tracks(&self, offset: u32, count: u32) -> Result<Vec<AudioTrack>, VkError> {
        if count == 0 {
            return Ok(Vec::new());
        }

        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare_cached(
            "
            SELECT id, owner_id, artist, title, duration, stream_url, cover_url
            FROM audio_tracks
            ORDER BY position ASC, owner_id ASC, id ASC
            LIMIT ?1 OFFSET ?2
            ",
        )?;

        let rows = stmt.query_map(params![i64::from(count), i64::from(offset)], |row| {
            let duration_i64: i64 = row.get(4)?;
            Ok(AudioTrack {
                id: row.get(0)?,
                owner_id: row.get(1)?,
                artist: row.get(2)?,
                title: row.get(3)?,
                duration_sec: u32::try_from(duration_i64.max(0)).unwrap_or(u32::MAX),
                stream_url: row.get(5)?,
                cover_url: row.get(6)?,
            })
        })?;

        let mut result = Vec::new();
        for track in rows {
            result.push(track?);
        }
        Ok(result)
    }

    pub fn clear_all(&self) -> Result<(), VkError> {
        let mut conn = self.lock_conn()?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM messages", [])?;
        tx.execute("DELETE FROM conversations", [])?;
        tx.execute("DELETE FROM users", [])?;
        tx.execute("DELETE FROM audio_tracks", [])?;
        tx.commit()?;

        conn.execute_batch("VACUUM;")?;
        if self.db_path.is_some() {
            let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
        }
        Ok(())
    }

    pub fn cache_size_bytes(&self) -> Result<u64, VkError> {
        if let Some(ref path) = self.db_path {
            // Ensure connection mutex is acquired briefly so we don't observe mid-vacuum state
            let _conn = self.lock_conn()?;
            let mut total = file_len_or_zero(path)?;
            let wal_path = PathBuf::from(format!("{}-wal", path.display()));
            let shm_path = PathBuf::from(format!("{}-shm", path.display()));
            total = total.saturating_add(file_len_or_zero(&wal_path)?);
            total = total.saturating_add(file_len_or_zero(&shm_path)?);
            Ok(total)
        } else {
            let conn = self.lock_conn()?;
            let page_count: i64 = conn.pragma_query_value(None, "page_count", |row| row.get(0))?;
            let page_size: i64 = conn.pragma_query_value(None, "page_size", |row| row.get(0))?;
            Ok((page_count.max(0) as u64).saturating_mul(page_size.max(0) as u64))
        }
    }

    pub fn save_draft(&self, peer_id: i64, text: &str, updated_at: i64) -> Result<(), VkError> {
        let conn = self.lock_conn()?;
        if text.trim().is_empty() {
            conn.execute("DELETE FROM drafts WHERE peer_id = ?1", params![peer_id])?;
        } else {
            conn.execute(
                "INSERT INTO drafts (peer_id, text, updated_at) VALUES (?1, ?2, ?3)
                 ON CONFLICT(peer_id) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at",
                params![peer_id, text, updated_at],
            )?;
        }
        Ok(())
    }

    pub fn get_draft(&self, peer_id: i64) -> Result<String, VkError> {
        let conn = self.lock_conn()?;
        let res: Option<String> = conn
            .query_row(
                "SELECT text FROM drafts WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(res.unwrap_or_default())
    }

    pub fn toggle_pin_conversation(&self, peer_id: i64, pinned_at: i64) -> Result<bool, VkError> {
        let conn = self.lock_conn()?;
        let exists: Option<i64> = conn
            .query_row(
                "SELECT peer_id FROM pinned_peers WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .optional()?;
        if exists.is_some() {
            conn.execute("DELETE FROM pinned_peers WHERE peer_id = ?1", params![peer_id])?;
            Ok(false)
        } else {
            conn.execute(
                "INSERT INTO pinned_peers (peer_id, pinned_at) VALUES (?1, ?2)",
                params![peer_id, pinned_at],
            )?;
            Ok(true)
        }
    }

    pub fn get_pinned_peers(&self) -> Result<Vec<i64>, VkError> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare("SELECT peer_id FROM pinned_peers ORDER BY pinned_at DESC")?;
        let rows = stmt.query_map([], |row| row.get::<_, i64>(0))?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn record_track_play(&self, track: &AudioTrack, played_at: i64) -> Result<(), VkError> {
        let conn = self.lock_conn()?;
        conn.execute(
            "INSERT INTO listening_history (track_id, owner_id, artist, title, duration, stream_url, cover_url, played_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                track.id,
                track.owner_id,
                track.artist,
                track.title,
                i64::from(track.duration_sec),
                track.stream_url,
                track.cover_url,
                played_at,
            ],
        )?;
        Ok(())
    }

    pub fn get_listening_history(&self, limit: u32) -> Result<Vec<AudioTrack>, VkError> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare(
            "SELECT track_id, owner_id, artist, title, duration, stream_url, cover_url
             FROM listening_history
             ORDER BY played_at DESC, rowid DESC
             LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![i64::from(limit)], |row| {
            Ok(AudioTrack {
                id: row.get(0)?,
                owner_id: row.get(1)?,
                artist: row.get(2)?,
                title: row.get(3)?,
                duration_sec: row.get::<_, i64>(4).unwrap_or(0).max(0) as u32,
                stream_url: row.get(5)?,
                cover_url: row.get(6)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn search_cached_messages(
        &self,
        query: &str,
        limit: u32,
    ) -> Result<Vec<MessageItem>, VkError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        let pattern = format!("%{trimmed}%");
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare(
            "SELECT id, peer_id, from_id, text, date, is_out, raw_json
             FROM messages
             WHERE text LIKE ?1
             ORDER BY date DESC, id DESC
             LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![pattern, i64::from(limit)], |row| {
            let raw_json: String = row.get(6)?;
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)? != 0,
                raw_json,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (id, peer_id, from_id, text, date, is_out, raw_json) = row?;
            let attachments = decode_attachments(&raw_json).unwrap_or_default();
            out.push(MessageItem {
                id,
                peer_id,
                from_id,
                text,
                date,
                is_out,
                attachments,
            });
        }
        Ok(out)
    }

    pub fn set_pref(&self, key: &str, value: &str) -> Result<(), VkError> {
        let conn = self.lock_conn()?;
        conn.execute(
            "INSERT INTO app_prefs (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn get_pref(&self, key: &str) -> Result<Option<String>, VkError> {
        let conn = self.lock_conn()?;
        let res: Option<String> = conn
            .query_row(
                "SELECT value FROM app_prefs WHERE key = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()?;
        Ok(res)
    }

    pub fn save_snippet(&self, title: &str, text: &str) -> Result<i64, VkError> {
        let conn = self.lock_conn()?;
        conn.execute(
            "INSERT INTO snippets (title, text) VALUES (?1, ?2)",
            params![title, text],
        )?;
        Ok(conn.last_insert_rowid())
    }

    pub fn get_snippets(&self) -> Result<Vec<SnippetItem>, VkError> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare("SELECT id, title, text FROM snippets ORDER BY id DESC")?;
        let rows = stmt.query_map([], |row| {
            Ok(SnippetItem {
                id: row.get(0)?,
                title: row.get(1)?,
                text: row.get(2)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn delete_snippet(&self, id: i64) -> Result<(), VkError> {
        let conn = self.lock_conn()?;
        conn.execute("DELETE FROM snippets WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn set_contact_note(&self, peer_id: i64, note: &str) -> Result<(), VkError> {
        let conn = self.lock_conn()?;
        if note.trim().is_empty() {
            conn.execute("DELETE FROM contact_notes WHERE peer_id = ?1", params![peer_id])?;
        } else {
            conn.execute(
                "INSERT INTO contact_notes (peer_id, note) VALUES (?1, ?2)
                 ON CONFLICT(peer_id) DO UPDATE SET note = excluded.note",
                params![peer_id, note],
            )?;
        }
        Ok(())
    }

    pub fn get_contact_note(&self, peer_id: i64) -> Result<String, VkError> {
        let conn = self.lock_conn()?;
        let note: Option<String> = conn
            .query_row(
                "SELECT note FROM contact_notes WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(note.unwrap_or_default())
    }

    pub fn toggle_watch_online(&self, user_id: i64) -> Result<bool, VkError> {
        let conn = self.lock_conn()?;
        let exists: Option<i64> = conn
            .query_row(
                "SELECT user_id FROM watched_online WHERE user_id = ?1",
                params![user_id],
                |row| row.get(0),
            )
            .optional()?;
        if exists.is_some() {
            conn.execute("DELETE FROM watched_online WHERE user_id = ?1", params![user_id])?;
            Ok(false)
        } else {
            conn.execute("INSERT INTO watched_online (user_id) VALUES (?1)", params![user_id])?;
            Ok(true)
        }
    }

    pub fn get_watched_online(&self) -> Result<Vec<i64>, VkError> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare("SELECT user_id FROM watched_online")?;
        let rows = stmt.query_map([], |row| row.get(0))?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn get_top_artists(&self, limit: u32) -> Result<Vec<ArtistStat>, VkError> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare(
            "SELECT artist, COUNT(*) as cnt FROM listening_history GROUP BY artist ORDER BY cnt DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |row| {
            Ok(ArtistStat {
                artist: row.get(0)?,
                play_count: row.get(1)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn toggle_watch_wall(&self, owner_id: i64) -> Result<bool, VkError> {
        let conn = self.lock_conn()?;
        let exists: Option<i64> = conn
            .query_row("SELECT owner_id FROM watched_walls WHERE owner_id = ?1", params![owner_id], |row| row.get(0))
            .optional()?;
        if exists.is_some() {
            conn.execute("DELETE FROM watched_walls WHERE owner_id = ?1", params![owner_id])?;
            Ok(false)
        } else {
            conn.execute("INSERT INTO watched_walls (owner_id) VALUES (?1)", params![owner_id])?;
            Ok(true)
        }
    }

    pub fn get_watched_walls(&self) -> Result<Vec<i64>, VkError> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare("SELECT owner_id FROM watched_walls")?;
        let rows = stmt.query_map([], |row| row.get(0))?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn upsert_saved_account(&self, user_id: i64, name: &str, avatar_url: Option<&str>) -> Result<(), VkError> {
        let conn = self.lock_conn()?;
        conn.execute(
            "INSERT INTO saved_accounts (user_id, name, avatar_url) VALUES (?1, ?2, ?3)
             ON CONFLICT(user_id) DO UPDATE SET name = excluded.name, avatar_url = excluded.avatar_url",
            params![user_id, name, avatar_url],
        )?;
        Ok(())
    }

    pub fn get_saved_accounts(&self) -> Result<Vec<AccountSummary>, VkError> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare("SELECT user_id, name, avatar_url FROM saved_accounts ORDER BY user_id ASC")?;
        let rows = stmt.query_map([], |row| {
            Ok(AccountSummary {
                user_id: row.get(0)?,
                name: row.get(1)?,
                avatar_url: row.get(2)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn remove_saved_account(&self, user_id: i64) -> Result<(), VkError> {
        let conn = self.lock_conn()?;
        conn.execute("DELETE FROM saved_accounts WHERE user_id = ?1", params![user_id])?;
        Ok(())
    }

    pub fn toggle_archive_conversation(&self, peer_id: i64) -> Result<bool, VkError> {
        let conn = self.lock_conn()?;
        let exists: Option<i64> = conn
            .query_row("SELECT peer_id FROM archived_peers WHERE peer_id = ?1", params![peer_id], |row| row.get(0))
            .optional()?;
        if exists.is_some() {
            conn.execute("DELETE FROM archived_peers WHERE peer_id = ?1", params![peer_id])?;
            Ok(false)
        } else {
            conn.execute("INSERT INTO archived_peers (peer_id) VALUES (?1)", params![peer_id])?;
            Ok(true)
        }
    }

    pub fn get_archived_peers(&self) -> Result<Vec<i64>, VkError> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare("SELECT peer_id FROM archived_peers")?;
        let rows = stmt.query_map([], |row| row.get(0))?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn get_chat_stats(&self, peer_id: i64) -> Result<ChatStats, VkError> {
        let conn = self.lock_conn()?;
        let total: u32 = conn.query_row(
            "SELECT COUNT(*) FROM messages WHERE peer_id = ?1",
            params![peer_id],
            |row| row.get(0),
        )?;
        let out_count: u32 = conn.query_row(
            "SELECT COUNT(*) FROM messages WHERE peer_id = ?1 AND is_out = 1",
            params![peer_id],
            |row| row.get(0),
        )?;
        let top_hour: u32 = conn
            .query_row(
                "SELECT CAST(strftime('%H', date, 'unixepoch', 'localtime') AS INTEGER) as hr
                 FROM messages WHERE peer_id = ?1
                 GROUP BY hr ORDER BY COUNT(*) DESC LIMIT 1",
                params![peer_id],
                |row| row.get(0),
            )
            .optional()?
            .unwrap_or(12);
        Ok(ChatStats {
            total_messages: total,
            outgoing_count: out_count,
            incoming_count: total.saturating_sub(out_count),
            top_hour,
        })
    }
}

fn file_len_or_zero(path: &Path) -> Result<u64, VkError> {
    match std::fs::metadata(path) {
        Ok(meta) => Ok(meta.len()),
        Err(err) if err.kind() == ErrorKind::NotFound => Ok(0),
        Err(err) => Err(VkError::Storage {
            details: format!("Failed to stat {}: {err}", path.display()),
        }),
    }
}

fn decode_attachments(raw_json: &str) -> Result<Vec<Attachment>, VkError> {
    let trimmed = raw_json.trim();
    if trimmed.is_empty() || trimmed == "{}" {
        return Ok(Vec::new());
    }
    serde_json::from_str::<Vec<Attachment>>(trimmed).map_err(|err| VkError::Storage {
        details: format!("Corrupt attachment JSON in messages.raw_json: {err}"),
    })
}

fn message_preview_text(msg: &MessageItem) -> String {
    if !msg.text.trim().is_empty() {
        return msg.text.clone();
    }
    match msg.attachments.first() {
        Some(Attachment::Photo { .. }) => "[Фото]".to_string(),
        Some(Attachment::Audio { .. }) => "[Аудио]".to_string(),
        Some(Attachment::Document { .. }) => "[Документ]".to_string(),
        Some(Attachment::Sticker { .. }) => "[Стикер]".to_string(),
        Some(Attachment::Link { .. }) => "[Ссылка]".to_string(),
        Some(Attachment::Video { .. }) => "[Видео]".to_string(),
        Some(Attachment::AudioMessage { .. }) => "[Голосовое сообщение]".to_string(),
        Some(Attachment::Poll { .. }) => "[Опрос]".to_string(),
        Some(Attachment::Reply { .. }) => "[Ответ]".to_string(),
        Some(Attachment::Forwarded { .. }) => "[Пересланное сообщение]".to_string(),
        Some(Attachment::BotKeyboard { .. }) => "[Клавиатура]".to_string(),
        Some(Attachment::Unknown { .. }) => "[Вложение]".to_string(),
        None => String::new(),
    }
}

fn enable_wal_with_retry(conn: &Connection, timeout: Duration) -> Result<(), VkError> {
    let deadline = Instant::now() + timeout;
    let mut backoff = Duration::from_millis(2);
    loop {
        match conn.pragma_update(None, "journal_mode", "WAL") {
            Ok(()) => return Ok(()),
            Err(err)
                if err.sqlite_error_code() == Some(ErrorCode::DatabaseBusy)
                    && Instant::now() < deadline =>
            {
                std::thread::sleep(backoff);
                backoff = (backoff * 2).min(Duration::from_millis(25));
            }
            Err(err) => return Err(err.into()),
        }
    }
}

fn migrate(conn: &mut Connection) -> Result<(), VkError> {
    let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if version >= 2 {
        return Ok(());
    }

    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let version: i64 = tx.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if version < 1 {
        tx.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS users (
                id         INTEGER PRIMARY KEY,
                first_name TEXT NOT NULL,
                last_name  TEXT NOT NULL,
                avatar_url TEXT,
                online     INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS conversations (
                peer_id       INTEGER PRIMARY KEY,
                title         TEXT NOT NULL,
                avatar_url    TEXT,
                last_msg_text TEXT NOT NULL,
                last_msg_date INTEGER NOT NULL,
                unread_count  INTEGER NOT NULL DEFAULT 0,
                is_muted      INTEGER NOT NULL DEFAULT 0,
                raw_json      TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX IF NOT EXISTS idx_conversations_last_msg_date
                ON conversations(last_msg_date DESC, peer_id DESC);

            CREATE TABLE IF NOT EXISTS messages (
                id       INTEGER PRIMARY KEY,
                peer_id  INTEGER NOT NULL,
                from_id  INTEGER NOT NULL,
                text     TEXT NOT NULL,
                date     INTEGER NOT NULL,
                is_out   INTEGER NOT NULL DEFAULT 0,
                raw_json TEXT NOT NULL DEFAULT '[]'
            );
            CREATE INDEX IF NOT EXISTS idx_messages_peer_date
                ON messages(peer_id, date DESC, id DESC);

            CREATE TABLE IF NOT EXISTS audio_tracks (
                id         INTEGER NOT NULL,
                owner_id   INTEGER NOT NULL,
                artist     TEXT NOT NULL,
                title      TEXT NOT NULL,
                duration   INTEGER NOT NULL,
                stream_url TEXT,
                cover_url  TEXT,
                position   INTEGER NOT NULL,
                PRIMARY KEY (owner_id, id)
            );
            CREATE INDEX IF NOT EXISTS idx_audio_tracks_position
                ON audio_tracks(position ASC, owner_id ASC, id ASC);

            PRAGMA user_version = 1;
            ",
        )?;
    }
    if version < 2 {
        tx.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS drafts (
                peer_id    INTEGER PRIMARY KEY,
                text       TEXT NOT NULL,
                updated_at INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS pinned_peers (
                peer_id   INTEGER PRIMARY KEY,
                pinned_at INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS listening_history (
                track_id   INTEGER NOT NULL,
                owner_id   INTEGER NOT NULL,
                artist     TEXT NOT NULL,
                title      TEXT NOT NULL,
                duration   INTEGER NOT NULL,
                stream_url TEXT,
                cover_url  TEXT,
                played_at  INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS app_prefs (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            PRAGMA user_version = 2;
            ",
        )?;
    }
    if version < 3 {
        tx.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS snippets (
                id    INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                text  TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS contact_notes (
                peer_id INTEGER PRIMARY KEY,
                note    TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS watched_online (
                user_id INTEGER PRIMARY KEY
            );

            PRAGMA user_version = 3;
            ",
        )?;
    }
    if version < 4 {
        tx.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS watched_walls (
                owner_id INTEGER PRIMARY KEY
            );

            CREATE TABLE IF NOT EXISTS saved_accounts (
                user_id    INTEGER PRIMARY KEY,
                name       TEXT NOT NULL,
                avatar_url TEXT
            );

            PRAGMA user_version = 4;
            ",
        )?;
    }
    if version < 5 {
        tx.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS archived_peers (
                peer_id INTEGER PRIMARY KEY
            );

            PRAGMA user_version = 5;
            ",
        )?;
    }
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use tempfile::TempDir;

    use super::*;

    #[test]
    fn test_storage_open_and_idempotent_migration() {
        let dir = TempDir::new().unwrap();
        let storage = Storage::open(dir.path()).unwrap();
        assert_eq!(storage.schema_version().unwrap(), 5);
        assert!(dir.path().join("cache.db").exists());
        assert_eq!(storage.db_path(), Some(dir.path().join("cache.db").as_path()));
        drop(storage);

        let reopened = Storage::open(dir.path()).unwrap();
        assert_eq!(reopened.schema_version().unwrap(), 5);
    }

    #[test]
    fn test_users_crud_and_upsert() {
        let storage = Storage::in_memory().unwrap();
        assert_eq!(storage.get_user(1).unwrap(), None);

        let u1 = UserProfile {
            id: 1,
            first_name: "Pavel".to_string(),
            last_name: "Durov".to_string(),
            avatar_url: Some("https://example.com/1.jpg".to_string()),
            online: true,
        };
        storage.upsert_users(std::slice::from_ref(&u1), 1000).unwrap();
        assert_eq!(storage.get_user(1).unwrap(), Some(u1));

        let u1_updated = UserProfile {
            id: 1,
            first_name: "Pavel".to_string(),
            last_name: "Updated".to_string(),
            avatar_url: None,
            online: false,
        };
        storage
            .upsert_users(std::slice::from_ref(&u1_updated), 2000)
            .unwrap();
        assert_eq!(storage.get_user(1).unwrap(), Some(u1_updated));
    }

    #[test]
    fn test_conversations_ordering_pagination_and_updates() {
        let storage = Storage::in_memory().unwrap();
        let c1 = ConversationItem {
            peer_id: 10,
            title: "Older".to_string(),
            avatar_url: None,
            last_message_text: "old".to_string(),
            last_message_date: 100,
            unread_count: 1,
            is_muted: false,
        };
        let c2 = ConversationItem {
            peer_id: 20,
            title: "Newer".to_string(),
            avatar_url: Some("https://example.com/c2.jpg".to_string()),
            last_message_text: "new".to_string(),
            last_message_date: 200,
            unread_count: 0,
            is_muted: true,
        };
        storage.upsert_conversations(&[c1.clone(), c2.clone()]).unwrap();

        assert_eq!(storage.get_conversations(0, 0).unwrap(), Vec::new());
        assert_eq!(
            storage.get_conversations(0, 10).unwrap(),
            vec![c2.clone(), c1.clone()]
        );
        assert_eq!(storage.get_conversations(1, 1).unwrap(), vec![c1.clone()]);

        // Incoming photo message without text updates preview & increments unread
        let incoming_photo = MessageItem {
            id: 500,
            peer_id: 10,
            from_id: 10,
            text: "  ".to_string(),
            date: 300,
            is_out: false,
            attachments: vec![Attachment::Photo {
                url: "https://example.com/p.jpg".to_string(),
                width: Some(800),
                height: Some(600),
            }],
        };
        storage
            .update_conversation_on_new_message(&incoming_photo)
            .unwrap();

        let top = storage.get_conversations(0, 1).unwrap();
        assert_eq!(top[0].peer_id, 10);
        assert_eq!(top[0].last_message_text, "[Фото]");
        assert_eq!(top[0].last_message_date, 300);
        assert_eq!(top[0].unread_count, 2);

        // Outgoing message resets unread to 0
        let outgoing = MessageItem {
            id: 501,
            peer_id: 10,
            from_id: 1,
            text: "Reply".to_string(),
            date: 305,
            is_out: true,
            attachments: vec![],
        };
        storage
            .update_conversation_on_new_message(&outgoing)
            .unwrap();
        let after_out = storage.get_conversations(0, 1).unwrap();
        assert_eq!(after_out[0].unread_count, 0);
        assert_eq!(after_out[0].last_message_text, "Reply");

        // mark_conversation_read clears unread_count
        let incoming_for_20 = MessageItem {
            id: 502,
            peer_id: 20,
            from_id: 20,
            text: "Ping".to_string(),
            date: 310,
            is_out: false,
            attachments: vec![],
        };
        storage
            .update_conversation_on_new_message(&incoming_for_20)
            .unwrap();
        assert_eq!(storage.get_conversations(0, 1).unwrap()[0].unread_count, 1);
        storage.mark_conversation_read(20).unwrap();
        assert_eq!(storage.get_conversations(0, 1).unwrap()[0].unread_count, 0);

        // Unknown peer_id is ignored cleanly
        let unknown_peer = MessageItem {
            id: 503,
            peer_id: 9999,
            from_id: 9999,
            text: "Hi".to_string(),
            date: 400,
            is_out: false,
            attachments: vec![],
        };
        storage
            .update_conversation_on_new_message(&unknown_peer)
            .unwrap();
    }

    #[test]
    fn test_messages_attachments_roundtrip_and_pagination() {
        let storage = Storage::in_memory().unwrap();
        let m1 = MessageItem {
            id: 1,
            peer_id: 100,
            from_id: 100,
            text: "First".to_string(),
            date: 10,
            is_out: false,
            attachments: vec![],
        };
        let m2 = MessageItem {
            id: 2,
            peer_id: 100,
            from_id: 1,
            text: "Second".to_string(),
            date: 20,
            is_out: true,
            attachments: vec![
                Attachment::Photo {
                    url: "https://example.com/1.jpg".to_string(),
                    width: Some(640),
                    height: Some(480),
                },
                Attachment::Sticker {
                    url: "https://example.com/s.png".to_string(),
                },
            ],
        };
        let other_peer = MessageItem {
            id: 3,
            peer_id: 200,
            from_id: 200,
            text: "Other".to_string(),
            date: 30,
            is_out: false,
            attachments: vec![],
        };

        storage
            .upsert_messages(&[m1.clone(), m2.clone(), other_peer])
            .unwrap();

        assert_eq!(storage.get_messages(100, 0, 0).unwrap(), Vec::new());
        assert_eq!(
            storage.get_messages(100, 0, 10).unwrap(),
            vec![m2.clone(), m1.clone()]
        );
        assert_eq!(storage.get_messages(100, 1, 1).unwrap(), vec![m1]);
    }

    #[test]
    fn test_audio_tracks_and_clear_all_shrinks_cache() {
        let dir = TempDir::new().unwrap();
        let storage = Storage::open(dir.path()).unwrap();

        let t1 = AudioTrack {
            id: 10,
            owner_id: 1,
            artist: "Artist A".to_string(),
            title: "Track 1".to_string(),
            duration_sec: 180,
            stream_url: Some("https://example.com/1.m3u8".to_string()),
            cover_url: None,
        };
        let t2 = AudioTrack {
            id: 20,
            owner_id: 1,
            artist: "Artist B".to_string(),
            title: "Track 2".to_string(),
            duration_sec: 240,
            stream_url: None,
            cover_url: Some("https://example.com/2.jpg".to_string()),
        };

        storage.upsert_audio_tracks(&[t1.clone(), t2.clone()], 0).unwrap();
        assert_eq!(storage.get_audio_tracks(0, 0).unwrap(), Vec::new());
        assert_eq!(
            storage.get_audio_tracks(0, 10).unwrap(),
            vec![t1.clone(), t2.clone()]
        );

        // Composite PK (owner_id, id) upsert updates metadata & position
        let t1_updated = AudioTrack {
            title: "Track 1 Remastered".to_string(),
            ..t1
        };
        storage
            .upsert_audio_tracks(std::slice::from_ref(&t1_updated), 5)
            .unwrap();
        assert_eq!(
            storage.get_audio_tracks(0, 10).unwrap(),
            vec![t2, t1_updated]
        );

        // Bulk insert messages to ensure VACUUM reduces cache size cleanly
        let big_text = "x".repeat(4096);
        let bulk: Vec<MessageItem> = (1..=50)
            .map(|id| MessageItem {
                id,
                peer_id: 1,
                from_id: 1,
                text: big_text.clone(),
                date: id,
                is_out: false,
                attachments: vec![],
            })
            .collect();
        storage.upsert_messages(&bulk).unwrap();

        let size_before = storage.cache_size_bytes().unwrap();
        assert!(size_before > 0);

        storage.clear_all().unwrap();
        assert!(storage.get_conversations(0, 10).unwrap().is_empty());
        assert!(storage.get_messages(1, 0, 10).unwrap().is_empty());
        assert!(storage.get_audio_tracks(0, 10).unwrap().is_empty());
        assert_eq!(storage.get_user(1).unwrap(), None);

        let size_after = storage.cache_size_bytes().unwrap();
        assert!(size_after < size_before);
    }

    #[test]
    fn test_storage_concurrent_open_on_fresh_dir() {
        use std::sync::{Arc, Barrier};
        use std::thread;

        const THREADS: usize = 6;
        const ROUNDS: usize = 6;

        for round in 0..ROUNDS {
            let dir = TempDir::new().unwrap();
            let db_dir = dir.path().join("fresh_nested");
            let open_barrier = Arc::new(Barrier::new(THREADS));
            let rw_barrier = Arc::new(Barrier::new(THREADS));

            let handles: Vec<_> = (0..THREADS)
                .map(|tid| {
                    let db_dir = db_dir.clone();
                    let open_barrier = Arc::clone(&open_barrier);
                    let rw_barrier = Arc::clone(&rw_barrier);
                    thread::spawn(move || -> Result<(), String> {
                        open_barrier.wait();
                        let storage = Storage::open(&db_dir)
                            .map_err(|err| format!("round {round} tid {tid} open: {err}"))?;

                        let version = storage.schema_version().map_err(|err| {
                            format!("round {round} tid {tid} schema_version: {err}")
                        })?;
                        if version != 5 {
                            return Err(format!(
                                "round {round} tid {tid} expected user_version 5, got {version}"
                            ));
                        }

                        let busy_timeout: i64 = {
                            let conn = storage
                                .lock_conn()
                                .map_err(|err| format!("round {round} tid {tid} lock_conn: {err}"))?;
                            conn.pragma_query_value(None, "busy_timeout", |row| row.get(0))
                                .map_err(|err| {
                                    format!("round {round} tid {tid} busy_timeout: {err}")
                                })?
                        };
                        if busy_timeout != 5000 {
                            return Err(format!(
                                "round {round} tid {tid} expected busy_timeout 5000, got {busy_timeout}"
                            ));
                        }

                        // Wait until all threads hold open Storage handles, then exercise concurrent writes/reads
                        rw_barrier.wait();

                        let uid = i64::try_from(tid + 1).unwrap();
                        let user = UserProfile {
                            id: uid,
                            first_name: format!("User{tid}"),
                            last_name: format!("Round{round}"),
                            avatar_url: None,
                            online: tid % 2 == 0,
                        };
                        storage
                            .upsert_users(std::slice::from_ref(&user), 1_700_000_000 + uid)
                            .map_err(|err| format!("round {round} tid {tid} upsert_users: {err}"))?;

                        let msg = MessageItem {
                            id: i64::try_from(round * 100 + tid + 1).unwrap(),
                            peer_id: 9001,
                            from_id: uid,
                            text: format!("msg r{round} t{tid}"),
                            date: 1_700_000_000 + uid,
                            is_out: false,
                            attachments: vec![],
                        };
                        storage
                            .upsert_messages(std::slice::from_ref(&msg))
                            .map_err(|err| {
                                format!("round {round} tid {tid} upsert_messages: {err}")
                            })?;

                        let loaded_user = storage
                            .get_user(uid)
                            .map_err(|err| format!("round {round} tid {tid} get_user: {err}"))?;
                        if loaded_user != Some(user) {
                            return Err(format!(
                                "round {round} tid {tid} get_user mismatch: {loaded_user:?}"
                            ));
                        }

                        let msgs = storage
                            .get_messages(9001, 0, 50)
                            .map_err(|err| format!("round {round} tid {tid} get_messages: {err}"))?;
                        if !msgs.iter().any(|m| m.id == msg.id) {
                            return Err(format!(
                                "round {round} tid {tid} missing own message {}",
                                msg.id
                            ));
                        }

                        Ok(())
                    })
                })
                .collect();

            let errors: Vec<String> = handles
                .into_iter()
                .filter_map(|h| h.join().expect("worker thread panicked").err())
                .collect();
            assert!(
                errors.is_empty(),
                "Concurrent Storage::open round {round} failed: {errors:?}"
            );

            // Verify WAL mode and user_version == 2 via an independent SQLite connection
            let check_conn = Connection::open(db_dir.join("cache.db")).unwrap();
            let journal_mode: String = check_conn
                .pragma_query_value(None, "journal_mode", |row| row.get(0))
                .unwrap();
            assert_eq!(journal_mode.to_ascii_lowercase(), "wal");

            let user_version: i64 = check_conn
                .pragma_query_value(None, "user_version", |row| row.get(0))
                .unwrap();
            assert_eq!(user_version, 5);

            // Verify all concurrent writes from all threads persisted
            let verify_storage = Storage::open(&db_dir).unwrap();
            for tid in 0..THREADS {
                let uid = i64::try_from(tid + 1).unwrap();
                assert!(
                    verify_storage.get_user(uid).unwrap().is_some(),
                    "round {round} missing user {uid}"
                );
            }
            let all_msgs = verify_storage.get_messages(9001, 0, 100).unwrap();
            assert_eq!(all_msgs.len(), THREADS);
        }
    }

    #[test]
    fn test_archive_watched_walls_saved_accounts_chat_stats_and_bot_keyboard_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let storage = Storage::open(dir.path()).unwrap();

        // Archive toggle
        assert!(storage.toggle_archive_conversation(101).unwrap());
        assert!(!storage.toggle_archive_conversation(101).unwrap());
        let storage2 = Storage::open(dir.path()).unwrap();
        assert!(storage2.toggle_archive_conversation(202).unwrap());
        assert_eq!(storage2.get_archived_peers().unwrap(), vec![202]);
        assert!(!storage2.toggle_archive_conversation(202).unwrap());
        assert!(storage2.get_archived_peers().unwrap().is_empty());

        // Watched walls
        assert!(storage.toggle_watch_wall(-500).unwrap());
        assert_eq!(storage.get_watched_walls().unwrap(), vec![-500]);
        assert!(!storage.toggle_watch_wall(-500).unwrap());
        assert!(storage.get_watched_walls().unwrap().is_empty());

        // Saved accounts
        storage
            .upsert_saved_account(42, "Test User", Some("https://vk.com/ava.jpg"))
            .unwrap();
        let accs = storage.get_saved_accounts().unwrap();
        assert_eq!(accs.len(), 1);
        assert_eq!(accs[0].user_id, 42);
        assert_eq!(accs[0].name, "Test User");
        storage.remove_saved_account(42).unwrap();
        assert!(storage.get_saved_accounts().unwrap().is_empty());

        // Chat stats & BotKeyboard attachment roundtrip
        let kb_msg = MessageItem {
            id: 1,
            peer_id: -777,
            from_id: -777,
            text: "Choose".to_string(),
            date: 1_700_000_000,
            is_out: false,
            attachments: vec![Attachment::BotKeyboard {
                inline: true,
                one_time: false,
                rows: vec![crate::models::BotKeyboardRow {
                    buttons: vec![crate::models::BotKeyboardButton {
                        action_type: "text".to_string(),
                        label: "Go".to_string(),
                        color: "primary".to_string(),
                        payload: Some("{\"go\":1}".to_string()),
                        link: None,
                    }],
                }],
            }],
        };
        let out_msg = MessageItem {
            id: 2,
            peer_id: -777,
            from_id: 10,
            text: "Go".to_string(),
            date: 1_700_000_060,
            is_out: true,
            attachments: vec![],
        };
        storage.upsert_messages(&[kb_msg.clone(), out_msg]).unwrap();
        let loaded = storage.get_messages(-777, 0, 10).unwrap();
        assert_eq!(loaded.len(), 2);
        assert!(loaded.iter().any(|m| m.id == 1 && m.attachments == kb_msg.attachments));

        let stats = storage.get_chat_stats(-777).unwrap();
        assert_eq!(stats.total_messages, 2);
        assert_eq!(stats.outgoing_count, 1);
        assert_eq!(stats.incoming_count, 1);
    }
}
