// Copyright (c) The Libra Core Contributors
// SPDX-License-Identifier: Apache-2.0

use crate::{
    backup::{
        BackupServiceClient, GlobalBackupOpt, StateSnapshotBackupController, StateSnapshotBackupOpt,
    },
    restore::{StateSnapshotRestoreController, StateSnapshotRestoreOpt},
    storage::{local_fs::LocalFs, BackupStorage},
};
use backup_service::start_backup_service;
use libra_config::config::NodeConfig;
use libra_proptest_helpers::ValueGenerator;
use libra_temppath::TempPath;
use libra_types::transaction::PRE_GENESIS_VERSION;
use libradb::{test_helper::arb_blocks_to_commit, LibraDB};
use std::sync::Arc;
use storage_interface::{DbReader, DbWriter};

fn tmp_db_empty() -> (TempPath, Arc<LibraDB>) {
    let tmpdir = TempPath::new();
    let db = Arc::new(LibraDB::new_for_test(&tmpdir));

    (tmpdir, db)
}

fn tmp_db_with_random_content() -> (TempPath, Arc<LibraDB>) {
    let (tmpdir, db) = tmp_db_empty();
    let mut cur_ver = 0;
    for (txns_to_commit, ledger_info_with_sigs) in
        ValueGenerator::new().generate(arb_blocks_to_commit())
    {
        db.save_transactions(
            &txns_to_commit,
            cur_ver, /* first_version */
            Some(&ledger_info_with_sigs),
        )
        .unwrap();
        cur_ver += txns_to_commit.len() as u64;
    }

    (tmpdir, db)
}

#[test]
fn end_to_end() {
    let (_src_db_dir, src_db) = tmp_db_with_random_content();
    let (_tgt_db_dir, tgt_db) = tmp_db_empty();
    let backup_dir = TempPath::new();
    backup_dir.create_as_dir().unwrap();
    let store: Arc<dyn BackupStorage> = Arc::new(LocalFs::new(backup_dir.path().to_path_buf()));

    let config = NodeConfig::random();
    let mut rt = start_backup_service(config.storage.backup_service_port, src_db);
    let client = Arc::new(BackupServiceClient::new(config.storage.backup_service_port));
    let (version, state_root_hash) = rt.block_on(client.get_latest_state_root()).unwrap();
    let manifest_handle = rt
        .block_on(
            StateSnapshotBackupController::new(
                StateSnapshotBackupOpt { version },
                GlobalBackupOpt {
                    max_chunk_size: 500,
                },
                client,
                Arc::clone(&store),
            )
            .run(),
        )
        .unwrap();

    rt.block_on(
        StateSnapshotRestoreController::new(
            StateSnapshotRestoreOpt {
                manifest_handle,
                version: PRE_GENESIS_VERSION,
            },
            store,
            Arc::clone(&tgt_db),
        )
        .run(),
    )
    .unwrap();
    assert_eq!(
        tgt_db
            .get_latest_tree_state()
            .unwrap()
            .account_state_root_hash,
        state_root_hash,
    );
}
