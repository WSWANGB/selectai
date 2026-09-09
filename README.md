# Ask Oracle AWR-only SQL 部署包

## 目的

把目前 APEX Application 105 使用的 Enterprise Manager AWR 能力部署到客戶既有的 Ask Oracle 環境。APEX Application 由交付人員另外使用 APEX Export／Import 搬移。

## 這個 SQL 會安裝

- APEX Schema 對 OMS 7803 的 Network ACL。
- APEX Web Credential 定義；執行時輸入客戶的 EM 帳密。
- 可管理、驗證及啟停 EM Database Target 的資料表、View 與 PL/SQL Package。
- 從 EM REST 取得 AWR Snapshot、產生 AWR HTML、保存報告及權限檢查。
- AWR 報告下載、初步分析、深度分析及分析結果快取。
- Select AI Agent Tools、Task、Agent Team；沿用客戶既有且已啟用的 Ask Oracle Profile。
- AWR 下載與分析所需的 ORDS REST Module／Handlers。
- 安裝後物件、Profile、Agent Team 與 ORDS 驗證。

## 不會安裝

- APEX Application UI（請另外 Import APEX Export）。
- LiteLLM、Gemini Credential 或任何新的模型端點。
- EMCLI、TFA、Alert Log collector、cron、Shell 或 Python 程式。
- 客戶的 EM Named Credential／Credential Set；必須先由 EM 管理員建立。
- 任何固定的客戶資料庫 Target；匯入後從「監控資料庫管理」頁面新增並驗證。

## 前置條件

- 客戶已有 APEX、ORDS、Ask Oracle，以及一個 `ENABLED` 的 Select AI Profile。
- APEX Parsing Schema 已存在，並可使用 `DBMS_CLOUD_AI`、`DBMS_CLOUD_AI_AGENT`。
- APEX DB 主機可連至 OMS HTTPS 7803。
- 已建立供 AWR 使用的 EM Database Credential Set。
- 已確認 Oracle Diagnostic Pack／AWR 授權與客戶資料保存政策。
- 準備可供資料庫驗證 OMS TLS 憑證的 Wallet。

## 執行

使用 SQLcl 或 SQL*Plus，以 SYS／DBA 帳號啟動：

```sql
@install_awr_only.sql
```

腳本會依序詢問 PDB、APEX Schema、Workspace、APEX Owner、OMS、Wallet、ORDS prefix、既有 Ask Oracle Profile，以及第一位 APEX 管理員。執行到 Application Schema 階段時，會再以隱藏輸入要求 Application Schema connect string。

完成後再匯入 APEX Application，進入「監控資料庫管理」新增 EM Target 與既有 Credential Set，驗證成功後即可從 Ask Oracle 查 Snapshot、產生、下載及分析 AWR。

