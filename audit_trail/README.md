# AuditTrail: theo dõi đổi Person của user và đổi Position (EBS 12.2)

Tài liệu tổng hợp các bước đã làm và kiểm chứng trên TEST, dùng làm hướng dẫn chạy trên PILOT/PROD.

## 1. Mục tiêu

| Cần theo dõi | Bảng gốc | Cột audit | Bảng log |
|---|---|---|---|
| User EBS được gắn sang Person khác | `APPLSYS.FND_USER` | `USER_ID`, `USER_NAME` (khóa), `EMPLOYEE_ID` | `APPLSYS.FND_USER_A` |
| Person đổi Position | `HR.PER_ALL_ASSIGNMENTS_F` | `ASSIGNMENT_ID`, `EFFECTIVE_START_DATE`, `EFFECTIVE_END_DATE` (khóa), `PERSON_ID`, `POSITION_ID` | `HR.PER_ALL_ASSIGNMENTS_F_A` |

Không audit các cột khác (`DESCRIPTION`, `EMAIL_ADDRESS`, `START_DATE`, `END_DATE`, `LAST_UPDATE_*`…), vì chúng sinh log không cần thiết. **Không bỏ các cột `*_ID` và các cột khóa.**

## 2. Cơ chế cần biết

- **Request tạo mọi object audit.** Request **AuditTrail Update Tables** tạo bảng log `<TABLE>_A`, 6 trigger `<TABLE>_AI/AU/AD/AH/AT/AC`, 3 procedure `<TABLE>_AIP/AUP/ADP` và các view `<TABLE>_AV#`, `<TABLE>_AC#`.
- **Bảng log lưu giá trị cũ.** Dòng `U` lưu giá trị **trước khi đổi** của các cột có thay đổi. Giá trị mới là giá trị cũ của lần đổi kế tiếp, hoặc giá trị hiện tại nếu đây là lần đổi cuối. Khi giá trị cũ là NULL, cột `AUDIT_TRUE_NULLS` đánh dấu `Y` ở vị trí của cột đó.
- **Procedure ghi theo thứ tự cột.** Lệnh ghi log là `INSERT ... VALUES(...)`, không ghi tên cột, nên thứ tự cột trong bảng `_A` phải khớp đúng với procedure.
- **Tắt, bật, Purge áp dụng cho cả group.** Mọi bảng trong group đều bị ảnh hưởng.
- **Đặc thù EBS 12.2:**
  - Trigger gắn vào editioning view `FND_USER#`, `PER_ALL_ASSIGNMENTS_F#`. Khi kiểm tra trigger, lọc theo **tên trigger** và `owner = 'APPS'`, không lọc theo `table_name`.
  - Các bảng seed như `FND_COLUMNS` có 2 bản ghi (`ZD_EDITION_NAME` = `SET1`, `SET2`). Câu join với `APPLSYS.FND_COLUMNS` sẽ ra gấp đôi. **Đây là bình thường, không xóa.**
- **Trigger INVALID là rủi ro lớn nhất.** Khi trigger bị INVALID, mọi lệnh ghi vào bảng gốc đều báo lỗi ORA-04098. Với `FND_USER`, điều này có thể làm lỗi đăng nhập. Xử lý ngay bằng `ALTER TRIGGER ... DISABLE`. Trigger **DISABLED** thì vô hại, chỉ là không ghi log.

## 3. Cài đặt mới

Làm với responsibility **System Administrator**.

1. **Bật profile:** **Profile > System**, `AuditTrail:Activate` = **Yes** ở mức Site. Kiểm tra bằng `SELECT fnd_profile.value('AUDITTRAIL:ACTIVATE') FROM dual;` (phải ra `Y`).
2. **Bật schema:** **Security > AuditTrail > Install**, tích **Audit Enabled** cho `APPLSYS` và `HR`.
   - Thiếu `HR` thì request **bỏ qua bảng assignment mà không báo lỗi**: request vẫn Completed Normal, nhưng bảng nằm mãi ở trạng thái `P`.
   ```sql
   SELECT u.oracle_username, s.state
   FROM apps.fnd_audit_schemas s JOIN apps.fnd_oracle_userid u ON u.oracle_id = s.oracle_id
   WHERE u.oracle_username IN ('APPLSYS','HR');   -- cả hai phải là R
   ```
3. **Khai báo cột:** **Security > AuditTrail > Tables**, khai báo đúng các cột ở mục 1. **Kiểm tra kỹ trước khi chạy request.** Sau khi chạy request, màn hình không cho bỏ cột nữa, phải làm theo mục 4.
4. **Tạo group:** **Security > AuditTrail > Groups**. Có thể dùng một group cho cả hai bảng; nên tách 2 group để làm lại bảng này không ảnh hưởng bảng kia. Group State: **Enable Requested**. Thêm `FND_USER` và `PER_ALL_ASSIGNMENTS_F`.
5. **Chạy request:** **AuditTrail Update Tables**, chờ **Completed Normal** và đọc log (không được có `Fatal error`).
6. **Kiểm tra:** chạy các câu ở mục 6. Kết quả mong đợi: group và các bảng ở `E`, mọi object **VALID**, trigger **ENABLED**.
7. **Cấp quyền đọc** cho user readonly:
   ```sql
   GRANT SELECT ON applsys.fnd_user_a         TO apps_readonly;
   GRANT SELECT ON hr.per_all_assignments_f_a TO apps_readonly;
   ```
8. **Test:**
   - Sửa Description của user: không sinh log.
   - Đổi Person: sinh 1 dòng `U`.
   - Đổi Position bằng Update: sinh dòng `I`. Bằng Correction: sinh dòng `U`.
   - Chạy báo cáo `04`.

## 4. Bỏ cột khỏi audit (sau khi đã chạy request)

1. **Chuẩn bị:** chọn giờ ít người dùng. Trên PILOT/PROD, sao lưu bảng `_A` của mọi bảng trong group (Purge có thể xóa bảng). Ghi lại danh sách grant trên các bảng `_A`.
2. **Tắt group:** **Disable - Purge Table**, Save, chạy request, chờ **Completed Normal**.
   - **Log có `Fatal error in fdadst`** (thiếu view): tạo view giả rồi chạy lại request:
     ```sql
     CREATE OR REPLACE VIEW apps.fnd_user_av1 AS SELECT * FROM applsys.fnd_user_a;
     CREATE OR REPLACE VIEW apps.fnd_user_ac1 AS SELECT * FROM applsys.fnd_user_a;
     ```
   - **Log có "Cannot disable auditing … FND_PROFILE_OPTION_VALUES / AP_SUPPLIERS"**: thuộc group khác, bỏ qua.
3. **Xác nhận không còn trigger** (bắt buộc, phải ra 0 dòng):
   ```sql
   SELECT trigger_name FROM dba_triggers
   WHERE owner = 'APPS'
     AND (trigger_name LIKE 'FND_USER\_A_' ESCAPE '\'
          OR trigger_name LIKE 'PER_ALL_ASSIGNMENTS_F\_A_' ESCAPE '\');
   ```
   Đồng thời trạng thái bảng không được là `E` hoặc `R`.
4. **Xóa cấu hình cột:** chạy script [`05_remove_audit_columns.sql`](05_remove_audit_columns.sql) bằng APPS.
   - Sửa `DEFINE p_table`, `p_drop_cols` ở đầu script. Danh sách cột phải bọc trong **nháy kép**, ví dụ `"'END_DATE','START_DATE'"`; thiếu nháy kép sẽ gây lỗi ORA-01722.
   - Script tự dừng nếu audit còn bật, nếu còn trigger, hoặc nếu danh sách có cột `*_ID`.
5. **Bảng `_A`:**
   - **Bảng còn:** bỏ cột thừa bằng `ALTER TABLE applsys.fnd_user_a DROP (...)`.
   - **Bảng đã mất và trạng thái bảng là `N`:** để request tự tạo lại khi bật group.
   - **Không drop bảng `_A` khi trạng thái bảng còn kẹt ở `E`.** Khi đó request sẽ không tạo lại bảng, nhưng vẫn tạo trigger, và trigger bị INVALID.
6. **Bật lại group:** **Enable Requested**, Save, chạy request.
7. **Kiểm tra** như mục 6, **cấp quyền lại** như bước 3.7 (bảng tạo mới thì mất grant), rồi test.

## 5. Sự cố đã gặp và cách xử lý

| Hiện tượng | Nguyên nhân | Xử lý |
|---|---|---|
| Trigger `FND_USER_A*` INVALID, nguy cơ lỗi đăng nhập | Bảng `FND_USER_A` bị drop khi trigger vẫn còn, hoặc request không tạo bảng | `ALTER TRIGGER ... DISABLE` ngay. Tạo lại bảng đúng cấu trúc, grant cho APPS, tạo synonym. `ALTER PROCEDURE/TRIGGER ... COMPILE`. Khi tất cả VALID thì `ENABLE` |
| Purge lỗi `Fatal error in fdadst` (`ER_AC1`) | Không tìm thấy view `_AC1`/`_AV1` để xóa | Tạo view giả (mục 4.2), chạy lại request |
| Bật lại nhưng request không tạo bảng `_A` (đi thẳng tới Create Triggers) | Trạng thái `FND_AUDIT_TABLES` kẹt ở `E` | Tạo bảng bằng tay theo thứ tự cột của procedure; tránh bằng cách không drop bảng `_A` |
| Bảng assignment kẹt ở `P`, không có bảng log | Schema `HR` chưa bật trong AuditTrail Install | Bật `HR` (mục 3.2), chạy lại request |
| Kiểm tra trigger ra 0 dòng dù trigger vẫn còn | Trên 12.2 trigger gắn vào `FND_USER#` | Lọc theo tên trigger, không lọc theo `table_name` |
| Kết quả join với `FND_COLUMNS` bị gấp đôi | 2 edition `SET1`/`SET2` | Bình thường, không xóa |
| `ORA-01722` khi chạy script 05 | `DEFINE` danh sách cột không có nháy kép | Bọc danh sách trong nháy kép |
| `ORA-01489` trong báo cáo | `LISTAGG` quá 4000 ký tự (Person gắn với nhiều user) | Báo cáo hiện 1 user + số user còn lại |

## 6. Câu kiểm tra

```sql
-- Trạng thái group / bảng
SELECT g.group_name, g.state group_state, t.table_name, at.state table_state
FROM apps.fnd_audit_tables at
JOIN apps.fnd_tables t ON t.application_id = at.table_app_id AND t.table_id = at.table_id
JOIN apps.fnd_audit_groups g ON g.application_id = at.audit_group_app_id
                            AND g.audit_group_id = at.audit_group_id
WHERE t.table_name IN ('FND_USER','PER_ALL_ASSIGNMENTS_F');

-- Cột đang audit
SELECT t.table_name, c.column_name, ac.schema_id, ac.state
FROM apps.fnd_audit_columns ac
JOIN apps.fnd_tables t  ON t.application_id = ac.table_app_id AND t.table_id = ac.table_id
JOIN apps.fnd_columns c ON c.application_id = ac.table_app_id
                       AND c.table_id = ac.table_id AND c.column_id = ac.column_id
WHERE t.table_name IN ('FND_USER','PER_ALL_ASSIGNMENTS_F')
ORDER BY 1, 2, 3;

-- Object audit
SELECT owner, object_name, object_type, status FROM dba_objects
WHERE object_name LIKE 'FND_USER\_A%' ESCAPE '\'
   OR object_name LIKE 'PER_ALL_ASSIGNMENTS_F\_A%' ESCAPE '\'
ORDER BY object_name, object_type;
-- FND_USER_AP_PKG là package chuẩn của EBS, không phải object audit.

-- Giám sát hằng ngày: phải ra 0 dòng
SELECT object_name, object_type FROM dba_objects
WHERE owner = 'APPS' AND status = 'INVALID'
  AND (object_name LIKE 'FND_USER\_A%' ESCAPE '\'
       OR object_name LIKE 'PER_ALL_ASSIGNMENTS_F\_A%' ESCAPE '\');
```

## 7. Báo cáo

[`04_report_user_person_position.sql`](04_report_user_person_position.sql): mỗi dòng là một sự kiện, sắp từ mới đến cũ.

- **`DOI_PERSON`:** user được gắn sang Person khác. Kèm Position của Person cũ và Person mới, lấy **theo ngày hiệu lực trong HR** tại ngày đổi.
- **`DOI_POSITION`:** Person đổi Position. `kieu_doi` = `UPDATE` (date-track Update, giữ lịch sử) hoặc `CORRECTION` (sửa đè).
  - `hieu_luc_tu`: ngày Position mới có hiệu lực.
  - `thoi_diem_doi`: thời điểm thao tác thật trên hệ thống.
- **Đơn vị / Phòng ban / Chức vụ:** lấy diễn giải từ Position Flexfield (KFF `POS`, structure `POSITION_FLEXFIELD`, `SEGMENT1/2/3`, value set `HSG_OU`, `PHONG_BAN`, `HSG_CHUC_VU`). Khi không tìm thấy diễn giải, cột Đơn vị hiện mã.

Lưu ý khi đọc báo cáo:
- Dòng `DOI_PERSON` hiện Position theo dữ liệu HR **hiện tại**. Nếu sau đó HR sửa bằng Correction, dòng này hiện Position đã sửa. Position trước khi sửa vẫn có ở dòng `DOI_POSITION` kiểu `CORRECTION`.
- Các thay đổi Position xảy ra trước khi bật audit assignment không có log.
- User readonly chạy được báo cáo (dùng `all_tab_columns`) khi đã được grant ở mục 3.7.

## 8. Vận hành

- **Dung lượng:** khoảng 70–80 byte mỗi dòng log. 20.000 dòng ≈ 1,6 MB. Chưa cần index. Nếu sau này cần thì tạo `(user_id, audit_timestamp)` với tên custom, và tạo lại sau mỗi lần Purge.
- **Hiệu năng:** trigger `FND_USER` chỉ chạy khi câu lệnh đụng `USER_ID`/`EMPLOYEE_ID`/`USER_NAME`, và chỉ ghi log khi giá trị thật sự đổi.
- **Sau mỗi lần Purge hoặc làm lại audit:** grant lại cho `APPS_READONLY`, và chạy câu giám sát ở mục 6.
- **Dọn log cũ:** dùng `DELETE ... WHERE audit_timestamp < ...` trên bảng `_A`. Không dùng Purge để dọn, vì Purge gỡ cả cấu hình audit.
- **Không dùng `AD_DD` cho bảng `_A`.** `AD_DD` chỉ đăng ký metadata cho bảng nghiệp vụ; bảng `_A` do AuditTrail tự quản lý.

## 9. Danh mục file

| File | Mục đích |
|---|---|
| [`04_report_user_person_position.sql`](04_report_user_person_position.sql) | Báo cáo tổng hợp đổi Person và đổi Position |
| [`05_remove_audit_columns.sql`](05_remove_audit_columns.sql) | Bỏ cột khỏi cấu hình audit (dùng chung cho mọi bảng) |
| [`02t_test_remove_description.sql`](02t_test_remove_description.sql) | Bản tập dượt trên TEST: bỏ `DESCRIPTION` khỏi `FND_USER` |

Các script `02_trim_fnd_user_audit_columns.sql`, `03_report_user_person_change.sql`, `98_restore_fnd_user_audit_columns.sql` được viết ở phiên làm việc trước, nằm trên máy người dùng (`D:\HSG-Cviec\audit_trail`), chưa có trong repo này. Script 05 thay thế được 02, báo cáo 04 thay thế được 03.
