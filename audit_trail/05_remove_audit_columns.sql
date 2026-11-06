-- =============================================================================
-- Go cot khoi cau hinh AuditTrail cua 1 bang (dung chung cho moi bang)
-- Chay bang: APPS, bang SQL*Plus (de WHENEVER SQLERROR dung ngay khi loi)
-- Dieu kien: group chua bang da Disable - Purge Table + da chay AuditTrail Update Tables
--            (khong con trigger audit cua bang).
-- Script chi xoa dong trong FND_AUDIT_COLUMNS; cot trong bang _A bo bang tay (buoc 5).
-- =============================================================================
SET SERVEROUTPUT ON
SET VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE p_table     = FND_USER
DEFINE p_drop_cols = "'LAST_UPDATED_BY','LAST_UPDATE_DATE','DESCRIPTION','END_DATE','START_DATE','EMAIL_ADDRESS'"
DEFINE bk_schema   = HSG
DEFINE do_backup   = N

PROMPT ===== [1] Cau hinh hien tai =====
SELECT c.column_name, ac.schema_id, ac.state
FROM   apps.fnd_audit_columns ac
JOIN   apps.fnd_tables t  ON t.application_id = ac.table_app_id AND t.table_id = ac.table_id
JOIN   apps.fnd_columns c ON c.application_id = ac.table_app_id
                         AND c.table_id = ac.table_id AND c.column_id = ac.column_id
WHERE  t.table_name = '&p_table'
ORDER  BY c.column_name, ac.schema_id;

PROMPT ===== [2] Sao luu FND_AUDIT_COLUMNS =====
DECLARE
  l_bk VARCHAR2(30) := 'BK_AUDCOL_' || TO_CHAR(SYSDATE, 'YYMMDDHH24MISS');
BEGIN
  IF '&do_backup' <> 'Y' THEN
    dbms_output.put_line('Bo qua sao luu (do_backup = &do_backup).');
    RETURN;
  END IF;
  EXECUTE IMMEDIATE
    'CREATE TABLE &bk_schema..' || l_bk || ' AS ' ||
    'SELECT ac.*, SYSDATE backup_date FROM apps.fnd_audit_columns ac ' ||
    'WHERE (ac.table_app_id, ac.table_id) IN ' ||
    '(SELECT application_id, table_id FROM apps.fnd_tables WHERE table_name = ''&p_table'')';
  dbms_output.put_line('Sao luu vao &bk_schema..' || l_bk);
END;
/

PROMPT ===== [3] Kiem tra dieu kien va xoa =====
DECLARE
  l_app_id   NUMBER;
  l_tab_id   NUMBER;
  l_active   NUMBER;
  l_triggers NUMBER;
  l_deleted  NUMBER;
BEGIN
  SELECT application_id, table_id INTO l_app_id, l_tab_id
  FROM   apps.fnd_tables WHERE table_name = '&p_table';

  SELECT COUNT(*) INTO l_active
  FROM   apps.fnd_audit_tables
  WHERE  table_app_id = l_app_id AND table_id = l_tab_id AND state IN ('E','R');

  SELECT COUNT(*) INTO l_triggers
  FROM   dba_triggers
  WHERE  owner = 'APPS'
    AND  trigger_name IN ('&p_table._AI','&p_table._AU','&p_table._AD',
                          '&p_table._AH','&p_table._AT','&p_table._AC');

  IF l_active > 0 OR l_triggers > 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Audit &p_table dang bat (tables E/R=' || l_active || ', triggers=' || l_triggers || '). Tat group truoc.');
  END IF;

  SELECT COUNT(*) INTO l_deleted
  FROM   apps.fnd_columns
  WHERE  application_id = l_app_id AND table_id = l_tab_id
    AND  column_name IN (&p_drop_cols)
    AND  column_name LIKE '%\_ID' ESCAPE '\';
  IF l_deleted > 0 THEN
    RAISE_APPLICATION_ERROR(-20003, 'Danh sach xoa co cot *_ID. Khong duoc xoa cot ID.');
  END IF;

  DELETE FROM apps.fnd_audit_columns ac
  WHERE  ac.table_app_id = l_app_id
    AND  ac.table_id = l_tab_id
    AND  ac.column_id IN (SELECT column_id FROM apps.fnd_columns
                          WHERE application_id = l_app_id AND table_id = l_tab_id
                            AND column_name IN (&p_drop_cols));
  l_deleted := SQL%ROWCOUNT;

  IF l_deleted = 0 THEN
    ROLLBACK;
    RAISE_APPLICATION_ERROR(-20002, 'Khong co dong nao de xoa. Kiem tra lai p_drop_cols.');
  END IF;

  COMMIT;
  dbms_output.put_line('Da xoa ' || l_deleted || ' dong cau hinh. COMMIT.');
END;
/

PROMPT ===== [4] Cau hinh sau khi xoa =====
SELECT c.column_name, ac.schema_id, ac.state
FROM   apps.fnd_audit_columns ac
JOIN   apps.fnd_tables t  ON t.application_id = ac.table_app_id AND t.table_id = ac.table_id
JOIN   apps.fnd_columns c ON c.application_id = ac.table_app_id
                         AND c.table_id = ac.table_id AND c.column_id = ac.column_id
WHERE  t.table_name = '&p_table'
ORDER  BY c.column_name, ac.schema_id;
