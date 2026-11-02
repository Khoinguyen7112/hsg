-- =============================================================================
-- TAP DUOT TREN TEST: Xoa cau hinh audit cot DESCRIPTION cua FND_USER
-- Muc dich : Chay thu cach go cot bang script truoc khi lam 02 tren PILOT.
-- Pham vi  : Xoa 2 dong DESCRIPTION (SCHEMA_ID -1 va 900) trong FND_AUDIT_COLUMNS
--            (TABLE_APP_ID = 0, TABLE_ID = 108). Giu USER_ID, EMPLOYEE_ID.
-- Dieu kien: Group XXFF_USER_PERSON_AUDIT da Disable - Purge Table + da chay
--            AuditTrail Update Tables (khong con trigger audit tren FND_USER).
-- Chay bang: APPS
-- =============================================================================
SET SERVEROUTPUT ON
SET VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

-- Schema chua bang sao luu (doi neu can)
DEFINE bk_schema = HSG

PROMPT ===== [1] Hien trang (mong doi 6 dong: USER_ID, EMPLOYEE_ID, DESCRIPTION x schema -1 / 900) =====
SELECT ac.schema_id, ac.column_id, c.column_name, ac.state, ac.sequence_id
FROM   apps.fnd_audit_columns ac
JOIN   apps.fnd_columns c ON c.application_id = ac.table_app_id
                         AND c.table_id = ac.table_id AND c.column_id = ac.column_id
WHERE  ac.table_app_id = 0 AND ac.table_id = 108
ORDER  BY c.column_name, ac.schema_id;

PROMPT ===== [2] Sao luu (neu bang sao luu da co tu lan chay truoc thi giu nguyen, khong tao lai) =====
DECLARE
  l_cnt NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_cnt FROM all_tables
  WHERE  owner = UPPER('&bk_schema') AND table_name = 'BK_FND_AUDIT_COLUMNS_108_TEST';
  IF l_cnt = 0 THEN
    EXECUTE IMMEDIATE
      'CREATE TABLE &bk_schema..bk_fnd_audit_columns_108_test AS '||
      'SELECT ac.table_app_id, ac.table_id, ac.column_id, ac.schema_id, ac.state, ac.sequence_id, '||
      '       ac.last_update_date, ac.last_updated_by, ac.last_update_login, '||
      '       ac.created_by, ac.creation_date, SYSDATE backup_date '||
      'FROM   apps.fnd_audit_columns ac '||
      'WHERE  ac.table_app_id = 0 AND ac.table_id = 108';
    dbms_output.put_line('Da tao bang sao luu &bk_schema..BK_FND_AUDIT_COLUMNS_108_TEST.');
  ELSE
    dbms_output.put_line('Bang sao luu da ton tai tu lan chay truoc, giu nguyen.');
  END IF;
END;
/
SELECT COUNT(*) bk_rows FROM &bk_schema..bk_fnd_audit_columns_108_test;

PROMPT ===== [3] Kiem tra dieu kien va xoa =====
DECLARE
  l_active    NUMBER;
  l_triggers  NUMBER;
  l_expected  NUMBER;
  l_deleted   NUMBER;
  l_kept      NUMBER;
BEGIN
  -- FND_USER khong duoc dang Enabled / Enable Requested trong bat ky group nao
  SELECT COUNT(*) INTO l_active
  FROM   apps.fnd_audit_tables
  WHERE  table_app_id = 0 AND table_id = 108 AND state IN ('E','R');

  SELECT COUNT(*) INTO l_triggers
  FROM   dba_triggers
  WHERE  owner = 'APPS'   -- 12.2: trigger gan vao editioning view FND_USER#, khong loc theo table_name
    AND  trigger_name IN ('FND_USER_AI','FND_USER_AU','FND_USER_AD',
                          'FND_USER_AH','FND_USER_AT','FND_USER_AC');

  IF l_active > 0 OR l_triggers > 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Audit FND_USER dang bat (tables E/R='||l_active||', triggers='||l_triggers||'). Tat group truoc.');
  END IF;

  SELECT COUNT(*) INTO l_expected
  FROM   apps.fnd_audit_columns ac
  WHERE  ac.table_app_id = 0 AND ac.table_id = 108
    AND  ac.column_id IN (SELECT column_id FROM apps.fnd_columns
                          WHERE application_id = 0 AND table_id = 108
                            AND column_name = 'DESCRIPTION');

  IF l_expected <> 2 THEN
    RAISE_APPLICATION_ERROR(-20002,
      'So dong cau hinh DESCRIPTION = '||l_expected||' (mong doi 2). Dung lai, khong xoa.');
  END IF;

  DELETE FROM apps.fnd_audit_columns ac
  WHERE  ac.table_app_id = 0
    AND  ac.table_id = 108
    AND  ac.column_id IN (SELECT column_id FROM apps.fnd_columns
                          WHERE application_id = 0 AND table_id = 108
                            AND column_name = 'DESCRIPTION');
  l_deleted := SQL%ROWCOUNT;

  -- USER_ID, EMPLOYEE_ID phai con nguyen 4 dong
  SELECT COUNT(*) INTO l_kept
  FROM   apps.fnd_audit_columns
  WHERE  table_app_id = 0 AND table_id = 108;

  IF l_deleted <> 2 OR l_kept <> 4 THEN
    ROLLBACK;
    RAISE_APPLICATION_ERROR(-20003,
      'Xoa '||l_deleted||' dong, con lai '||l_kept||' (mong doi 2 / 4). Da ROLLBACK.');
  END IF;

  COMMIT;
  dbms_output.put_line('Da xoa '||l_deleted||' dong DESCRIPTION, con lai '||l_kept||' dong. COMMIT.');
END;
/

PROMPT ===== [4] Kiem tra sau (mong doi 4 dong: USER_ID, EMPLOYEE_ID x schema -1 / 900) =====
SELECT ac.schema_id, ac.column_id, c.column_name, ac.state, ac.sequence_id
FROM   apps.fnd_audit_columns ac
JOIN   apps.fnd_columns c ON c.application_id = ac.table_app_id
                         AND c.table_id = ac.table_id AND c.column_id = ac.column_id
WHERE  ac.table_app_id = 0 AND ac.table_id = 108
ORDER  BY c.column_name, ac.schema_id;

-- Go nguoc neu can:
-- INSERT INTO apps.fnd_audit_columns
--       (table_app_id, table_id, column_id, schema_id, state, sequence_id,
--        last_update_date, last_updated_by, last_update_login, created_by, creation_date)
-- SELECT table_app_id, table_id, column_id, schema_id, state, sequence_id,
--        last_update_date, last_updated_by, last_update_login, created_by, creation_date
-- FROM   &bk_schema..bk_fnd_audit_columns_108_test b
-- WHERE  NOT EXISTS (SELECT 1 FROM apps.fnd_audit_columns a
--                    WHERE a.table_app_id = b.table_app_id AND a.table_id = b.table_id
--                      AND a.column_id = b.column_id AND a.schema_id = b.schema_id);
-- COMMIT;
