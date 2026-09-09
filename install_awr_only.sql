--------------------------------------------------------------------------------
-- Ask Oracle / APEX EM AWR - Customer SQL-only installer
-- Run in SQLcl or SQL*Plus using an account with SYS/DBA privileges.
--------------------------------------------------------------------------------
set echo on
set verify off
set define on
set serveroutput on size unlimited
whenever sqlerror exit sql.sqlcode rollback

accept PDB_NAME char prompt 'Target PDB name: '
accept APP_SCHEMA char prompt 'Existing APEX parsing schema: '
accept APEX_WORKSPACE char prompt 'Existing APEX workspace: '
accept APEX_OWNER char prompt 'Installed APEX owner (example APEX_240200): '
accept EM_HOST char prompt 'Enterprise Manager OMS host: '
accept EM_PORT number default 7803 prompt 'OMS HTTPS port [7803]: '
accept EM_USERNAME char default SYSMAN prompt 'OMS user [SYSMAN]: '
accept EM_WALLET_PATH char prompt 'Database wallet path (file:/...): '
accept ORDS_MODULE char default customer-ai-api prompt 'ORDS module prefix [customer-ai-api]: '
accept ASK_ORACLE_PROFILE char prompt 'Existing ENABLED Ask Oracle Select AI profile: '
accept INITIAL_APEX_ADMIN char prompt 'Initial APEX administrator username: '


prompt ================================================================================
prompt Installing: 10_install_apex_em_awr_new_all_in_one.sql
prompt ================================================================================
--------------------------------------------------------------------------------
-- Application 105 APEX-based OEM AWR - ALL IN ONE
-- Customer APEX/PLSQL deployment (APEX/PLSQL runtime only).
-- Run as SYS or another privileged account connected to the CDB.
-- Required SQL*Plus input: EM_PASSWORD.
--------------------------------------------------------------------------------
set define on
set serveroutput on size unlimited
set sqlblanklines on
whenever sqlerror exit sql.sqlcode rollback

define EM_QUERY_URL = https://&&EM_HOST:&&EM_PORT/em/websvcs/restful/emws/oracle.sysman.db/executesql/target/query/v1

prompt Enter the OEM password for &EM_USERNAME when prompted.
accept EM_PASSWORD char prompt 'OEM password: ' hide

alter session set container=&PDB_NAME;

prompt === 1. NETWORK ACL ===
begin
  dbms_network_acl_admin.append_host_ace(
    host       => '&EM_HOST', lower_port => &EM_PORT, upper_port => &EM_PORT,
    ace        => xs$ace_type(privilege_list => xs$name_list('connect'),
      principal_name => '&APP_SCHEMA', principal_type => xs_acl.ptype_db));
exception when others then
  if sqlcode not in (-24243, -46212) then raise; end if;
end;
/
begin
  dbms_network_acl_admin.append_host_ace(
    host => '&EM_HOST',
    ace  => xs$ace_type(privilege_list => xs$name_list('resolve'),
      principal_name => '&APP_SCHEMA', principal_type => xs_acl.ptype_db));
exception when others then
  if sqlcode not in (-24243, -46212) then raise; end if;
end;
/
begin
  dbms_network_acl_admin.append_host_ace(
    host       => '&EM_HOST', lower_port => &EM_PORT, upper_port => &EM_PORT,
    ace        => xs$ace_type(privilege_list => xs$name_list('connect'),
      principal_name => '&APEX_OWNER', principal_type => xs_acl.ptype_db));
exception when others then
  if sqlcode not in (-24243, -46212) then raise; end if;
end;
/
begin
  dbms_network_acl_admin.append_host_ace(
    host => '&EM_HOST',
    ace  => xs$ace_type(privilege_list => xs$name_list('resolve'),
      principal_name => '&APEX_OWNER', principal_type => xs_acl.ptype_db));
exception when others then
  if sqlcode not in (-24243, -46212) then raise; end if;
end;
/
begin
  dbms_network_acl_admin.append_host_ace(
    host => 'inference.generativeai.ap-osaka-1.oci.oraclecloud.com',
    lower_port => 443, upper_port => 443,
    ace => xs$ace_type(privilege_list => xs$name_list('connect'),
      principal_name => '&APP_SCHEMA', principal_type => xs_acl.ptype_db));
exception when others then
  if sqlcode not in (-24243, -46212) then raise; end if;
end;
/
begin
  dbms_network_acl_admin.append_host_ace(
    host => 'inference.generativeai.ap-osaka-1.oci.oraclecloud.com',
    ace => xs$ace_type(privilege_list => xs$name_list('resolve'),
      principal_name => '&APP_SCHEMA', principal_type => xs_acl.ptype_db));
exception when others then
  if sqlcode not in (-24243, -46212) then raise; end if;
end;
/

prompt === 2. APEX WEB CREDENTIAL ===
declare
  l_workspace_id number;
begin
  l_workspace_id := apex_util.find_security_group_id('&APEX_WORKSPACE');
  apex_util.set_security_group_id(l_workspace_id);
  begin apex_credential.drop_credential('&&APEX_WORKSPACE._EM_REST'); exception when others then null; end;
  apex_credential.create_credential(
    p_credential_name      => '&&APEX_WORKSPACE EM REST',
    p_credential_static_id => '&&APEX_WORKSPACE._EM_REST',
    p_authentication_type  => apex_credential.c_type_basic,
    p_allowed_urls         => apex_t_varchar2('&EM_QUERY_URL'),
    p_prompt_on_install    => false,
    p_credential_comment   => 'Application 105 access to OEM target query REST API');
  apex_credential.set_persistent_credentials(
    p_credential_static_id => '&&APEX_WORKSPACE._EM_REST',
    p_username => '&EM_USERNAME', p_password => '&EM_PASSWORD');
end;
/

prompt === 3. TARGET MAPPING ===
begin
  execute immediate q'[
    create table &APP_SCHEMA..ai_tbl_apex_em_target_mapping (
      em_target_name varchar2(128) primary key,
      em_target_type varchar2(128) default 'oracle_database' not null,
      db_display_name varchar2(256) not null,
      em_db_credential_set varchar2(128) not null,
      enabled varchar2(1) default 'Y' not null,
      created_at timestamp with time zone default systimestamp not null,
      constraint ck_apex_em_target_enabled check (enabled in ('Y','N')),
      constraint ck_apex_em_target_type check (em_target_type='oracle_database'))]';
exception when others then if sqlcode != -955 then raise; end if;
end;
/
create or replace view &APP_SCHEMA..ai_vw_apex_em_targets as
select em_target_name, em_target_type, db_display_name, em_db_credential_set, enabled
from &APP_SCHEMA..ai_tbl_apex_em_target_mapping where enabled='Y';

-- No EM targets are seeded; use the APEX monitoring database administration page.

prompt === 4. REPORT STORAGE ===
begin
  execute immediate q'[
    create table &APP_SCHEMA..dba_assist_em_awr_reports (
      report_id varchar2(32) primary key,
      source_system varchar2(30) default 'ORACLE_ENTERPRISE_MANAGER_REST' not null,
      em_target_name varchar2(128) not null, db_name varchar2(128) not null,
      dbid number not null, instance_number number not null,
      begin_snap number not null, end_snap number not null,
      report_format varchar2(10) default 'HTML' not null,
      report_status varchar2(20) not null, report_html clob, report_bytes number,
      requested_by varchar2(128), created_at timestamp with time zone default systimestamp not null,
      expires_at timestamp with time zone, error_message varchar2(4000),
      constraint ck_em_awr_snap_range check (end_snap > begin_snap),
      constraint ck_em_awr_format check (report_format='HTML'),
      constraint ck_em_awr_status check (report_status in ('READY','FAILED')))]';
exception when others then if sqlcode != -955 then raise; end if;
end;
/
create or replace view &APP_SCHEMA..v_dba_assist_em_awr_reports as
select report_id, source_system, em_target_name, db_name, dbid, instance_number,
       begin_snap, end_snap, report_format, report_status, report_bytes,
       requested_by, created_at, expires_at, error_message
from &APP_SCHEMA..dba_assist_em_awr_reports;

prompt === 5. AWR RUNTIME PACKAGE AND FUNCTIONS ===
create or replace package &APP_SCHEMA..ai_pkg_apex_em_awr authid definer as
  function list_targets return clob;
  function health_check(p_target_name in varchar2) return clob;
  function list_snapshots(p_target_name in varchar2,
                          p_hours_back in number default 24) return clob;
  function collect_analysis_evidence(
    p_target_name in varchar2,
    p_begin_snap in number,
    p_end_snap in number) return clob;
  function generate_report(
    p_target_name in varchar2,
    p_begin_snap in number,
    p_end_snap in number,
    p_awr_generate_confirmed in varchar2) return clob;
  function get_report_html(p_report_id in varchar2) return clob;
end ai_pkg_apex_em_awr;
/

create or replace package body &APP_SCHEMA..ai_pkg_apex_em_awr as
  c_workspace      constant varchar2(30)  := '&APEX_WORKSPACE';
  c_target_type    constant varchar2(128) := 'oracle_database';
  c_web_credential constant varchar2(128) := '&&APEX_WORKSPACE._EM_REST';
  c_wallet_path    constant varchar2(512) := '&EM_WALLET_PATH';
  c_query_url      constant varchar2(1000) := '&EM_QUERY_URL';
  c_analysis_profile constant varchar2(128) := '&DEEPSEEK_PROFILE';

  function target_name(p_requested varchar2) return varchar2 is
    l_value varchar2(128);
  begin
    if trim(p_requested) is null then
      raise_application_error(-20500,
        'TARGET is required. Call LIST_TARGETS first, then supply TARGET=<name>.');
    end if;
    select em_target_name into l_value
    from ai_tbl_apex_em_target_mapping
    where enabled='Y' and upper(em_target_name)=upper(trim(p_requested));
    return l_value;
  exception when no_data_found then
    raise_application_error(-20500,'Unknown or disabled OEM TARGET='||p_requested);
  end;

  function target_credential(p_target_name varchar2) return varchar2 is
    l_value varchar2(128);
  begin
    select em_db_credential_set into l_value
    from ai_tbl_apex_em_target_mapping
    where enabled='Y' and em_target_name=p_target_name;
    return l_value;
  end;

  function list_targets return clob is
    l_result json_object_t := json_object_t();
    l_rows json_array_t := json_array_t();
    l_row json_object_t;
  begin
    for r in (select em_target_name,em_target_type,db_display_name
              from ai_vw_apex_em_targets order by db_display_name) loop
      l_row := json_object_t();
      l_row.put('TARGET',r.em_target_name);
      l_row.put('TARGET_TYPE',r.em_target_type);
      l_row.put('DISPLAY_NAME',r.db_display_name);
      l_rows.append(l_row);
    end loop;
    l_result.put('status','SELECT_TARGET');
    l_result.put('targets',l_rows);
    l_result.put('next_prompt','Supply TARGET=<name> and the requested time range.');
    return l_result.to_clob();
  end;

  function error_json(p_code varchar2, p_message varchar2) return clob is
    l_json json_object_t := json_object_t();
  begin
    l_json.put('status','ERROR');
    l_json.put('error_code',p_code);
    l_json.put('message',p_message);
    l_json.put('source_system','ORACLE_ENTERPRISE_MANAGER_REST');
    return l_json.to_clob();
  end;

  function em_query(p_target_name varchar2, p_sql clob,
                    p_max_rows number default 1000) return clob is
    l_payload json_object_t := json_object_t();
    l_cred json_object_t := json_object_t();
    l_response clob;
  begin
    apex_util.set_security_group_id(apex_util.find_security_group_id(c_workspace));
    l_cred.put('DBCredsMonitoring',target_credential(p_target_name));
    l_payload.put('targetName',p_target_name);
    l_payload.put('targetType',c_target_type);
    l_payload.put('sqlStatement',p_sql);
    l_payload.put('credential',l_cred);
    l_payload.put('maxRowLimit',p_max_rows);
    l_payload.put('maxColumnLimit',20);
    apex_web_service.set_request_headers(
      p_name_01=>'Content-Type',p_value_01=>'application/json',p_reset=>true);
    l_response := apex_web_service.make_rest_request(
      p_url=>c_query_url,p_http_method=>'POST',p_body=>l_payload.to_clob(),
      p_transfer_timeout=>180,p_wallet_path=>c_wallet_path,
      p_credential_static_id=>c_web_credential);
    if apex_web_service.g_status_code != 200 then
      raise_application_error(-20501,'OEM REST HTTP '||
        apex_web_service.g_status_code||': '||dbms_lob.substr(l_response,1000,1));
    end if;
    return l_response;
  end;

  function health_check(p_target_name in varchar2) return clob is
    l_target varchar2(128) := target_name(p_target_name);
  begin
    return em_query(l_target,'select name, dbid, open_mode from v$database',10);
  exception when others then
    return error_json('EM_HEALTH_CHECK_FAILED',sqlerrm);
  end;

  function list_snapshots(p_target_name in varchar2,
                          p_hours_back in number default 24) return clob is
    l_hours pls_integer := trunc(nvl(p_hours_back,24));
    l_sql varchar2(4000);
    l_target varchar2(128) := target_name(p_target_name);
  begin
    if l_hours < 1 or l_hours >= 336 then
      return error_json('TIME_RANGE_NOT_ALLOWED',
        'Requested lookback must be at least 1 hour and less than 14 days (336 hours).');
    end if;
    l_sql :=
      'select s.dbid, s.instance_number, '||
      '(select max(di.instance_name) from dba_hist_database_instance di '||
      'where di.dbid=s.dbid and di.instance_number=s.instance_number) instance_name, '||
      's.snap_id, to_char(begin_interval_time,''YYYY-MM-DD HH24:MI:SS'') begin_time, '||
      'to_char(end_interval_time,''YYYY-MM-DD HH24:MI:SS'') end_time, '||
      'to_char(startup_time,''YYYY-MM-DD HH24:MI:SS'') startup_time '||
      'from dba_hist_snapshot s where dbid=(select dbid from v$database) '||
      'and end_interval_time >= systimestamp-numtodsinterval('||l_hours||',''HOUR'') '||
      'and begin_interval_time >= systimestamp-numtodsinterval(30,''DAY'') '||
      'order by instance_number,snap_id';
    return em_query(l_target,l_sql,1000);
  exception when others then
    return error_json('EM_SNAPSHOT_LIST_FAILED',sqlerrm);
  end;

  function collect_analysis_evidence(
    p_target_name in varchar2,
    p_begin_snap in number,
    p_end_snap in number) return clob is
    l_result clob;
    l_sql varchar2(32767);
    procedure append_section(p_name varchar2, p_value clob) is
    begin
      if l_result is null then dbms_lob.createtemporary(l_result,true); end if;
      dbms_lob.append(l_result,to_clob(chr(10)||'=== '||p_name||' ==='||chr(10)));
      if p_value is not null then dbms_lob.append(l_result,p_value); end if;
    end;
  begin
    if p_begin_snap is null or p_end_snap is null or p_begin_snap < 1
       or p_end_snap <= p_begin_snap or p_end_snap-p_begin_snap >= 336 then
      return error_json('INVALID_ANALYSIS_RANGE',
        'AWR analysis requires a valid snapshot range shorter than 14 days.');
    end if;

    begin
      l_sql :=
        'select metric_name,round(avg(average),2) average_value,'||
        'round(max(maxval),2) peak_value,max(metric_unit) metric_unit '||
        'from dba_hist_sysmetric_summary '||
        'where dbid=(select dbid from v$database) '||
        'and snap_id>'||trunc(p_begin_snap)||' and snap_id<='||trunc(p_end_snap)||' '||
        'and metric_name in (''Average Active Sessions'',''Database CPU Time Ratio'','||
        '''Database Wait Time Ratio'',''Host CPU Utilization (%)'','||
        '''Physical Read Total Bytes Per Sec'',''Physical Write Total Bytes Per Sec'','||
        '''Redo Generated Per Sec'',''Executions Per Sec'') '||
        'group by metric_name order by metric_name';
      append_section('LOAD_AND_CPU_METRICS',em_query(p_target_name,l_sql,20));
    exception when others then
      append_section('LOAD_AND_CPU_METRICS_ERROR',to_clob(sqlerrm));
    end;

    begin
      l_sql :=
        'select * from (select event_name,wait_class,'||
        'round(sum(greatest(time_waited_micro_end-time_waited_micro_begin,0))/1000000,2) waited_seconds,'||
        'sum(greatest(total_waits_end-total_waits_begin,0)) total_waits from ('||
        'select instance_number,event_name,wait_class,'||
        'min(time_waited_micro) keep (dense_rank first order by snap_id) time_waited_micro_begin,'||
        'max(time_waited_micro) keep (dense_rank last order by snap_id) time_waited_micro_end,'||
        'min(total_waits) keep (dense_rank first order by snap_id) total_waits_begin,'||
        'max(total_waits) keep (dense_rank last order by snap_id) total_waits_end '||
        'from dba_hist_system_event where dbid=(select dbid from v$database) '||
        'and snap_id between '||trunc(p_begin_snap)||' and '||trunc(p_end_snap)||' '||
        'and wait_class<>''Idle'' group by instance_number,event_name,wait_class) '||
        'group by event_name,wait_class '||
        'order by sum(greatest(time_waited_micro_end-time_waited_micro_begin,0)) desc) '||
        'where rownum<=10';
      append_section('TOP_FOREGROUND_WAIT_EVENTS',em_query(p_target_name,l_sql,10));
    exception when others then
      append_section('TOP_FOREGROUND_WAIT_EVENTS_ERROR',to_clob(sqlerrm));
    end;

    begin
      l_sql :=
        'select * from (select st.sql_id,st.plan_hash_value,'||
        'round(sum(st.elapsed_time_delta)/1000000,2) elapsed_seconds,'||
        'round(sum(st.cpu_time_delta)/1000000,2) cpu_seconds,'||
        'sum(st.executions_delta) executions,sum(st.buffer_gets_delta) buffer_gets,'||
        'sum(st.disk_reads_delta) disk_reads,'||
        'substr(max(dbms_lob.substr(tx.sql_text,500,1)),1,500) sql_text '||
        'from dba_hist_sqlstat st join dba_hist_sqltext tx '||
        'on tx.dbid=st.dbid and tx.sql_id=st.sql_id '||
        'where st.dbid=(select dbid from v$database) '||
        'and st.snap_id>'||trunc(p_begin_snap)||' and st.snap_id<='||trunc(p_end_snap)||' '||
        'group by st.sql_id,st.plan_hash_value '||
        'order by sum(st.elapsed_time_delta) desc) where rownum<=10';
      append_section('TOP_SQL_AND_PLAN_HASH',em_query(p_target_name,l_sql,10));
    exception when others then
      append_section('TOP_SQL_AND_PLAN_HASH_ERROR',to_clob(sqlerrm));
    end;

    begin
      l_sql :=
        'select * from (select p.sql_id,p.plan_hash_value,p.id,p.parent_id,p.depth,'||
        'p.operation,p.options,p.object_owner,p.object_name,p.cost,p.cardinality '||
        'from dba_hist_sql_plan p where p.dbid=(select dbid from v$database) '||
        'and (p.sql_id,p.plan_hash_value) in (select sql_id,plan_hash_value from ('||
        'select st.sql_id,st.plan_hash_value,sum(st.elapsed_time_delta) elapsed_time '||
        'from dba_hist_sqlstat st where st.dbid=(select dbid from v$database) '||
        'and st.snap_id>'||trunc(p_begin_snap)||' and st.snap_id<='||trunc(p_end_snap)||' '||
        'group by st.sql_id,st.plan_hash_value order by sum(st.elapsed_time_delta) desc) '||
        'where rownum<=5) order by p.sql_id,p.plan_hash_value,p.id) where rownum<=50';
      append_section('TOP_SQL_PLAN_OPERATIONS',em_query(p_target_name,l_sql,50));
    exception when others then
      append_section('TOP_SQL_PLAN_OPERATIONS_ERROR',to_clob(sqlerrm));
    end;

    return l_result;
  exception when others then
    return error_json('AWR_EVIDENCE_COLLECTION_FAILED',sqlerrm);
  end;

  function generate_report(
    p_target_name in varchar2,
    p_begin_snap in number,
    p_end_snap in number,
    p_awr_generate_confirmed in varchar2) return clob is
    pragma autonomous_transaction;
    l_validation clob;
    l_report_json clob;
    l_root json_object_t;
    l_rows json_array_t;
    l_row json_object_t;
    l_html clob;
    l_report_id varchar2(32) := rawtohex(sys_guid());
    l_dbid number;
    l_instance number;
    l_sql varchar2(4000);
    l_result json_object_t := json_object_t();
    l_target varchar2(128);
    l_analysis_evidence clob;
    l_llm_analysis clob;
    l_analysis_status varchar2(30) := 'NOT_RUN';
  begin
    l_target := target_name(p_target_name);
    if upper(trim(p_awr_generate_confirmed)) != 'YES' then
      return error_json('CONFIRMATION_REQUIRED',
        'Supply AWR_GENERATE_CONFIRMED=YES after confirming BEGIN_SNAP and END_SNAP.');
    end if;
    if p_begin_snap is null or p_end_snap is null or p_begin_snap < 1
       or p_end_snap <= p_begin_snap or p_end_snap-p_begin_snap >= 336 then
      return error_json('INVALID_SNAPSHOT_RANGE',
        'Snapshots must be positive, END_SNAP must exceed BEGIN_SNAP, and span must be less than 14 days.');
    end if;

    l_sql := 'select dbid,instance_number,snap_id,'||
      'to_char(startup_time,''YYYY-MM-DD HH24:MI:SS'') startup_time '||
      'from dba_hist_snapshot where dbid=(select dbid from v$database) '||
      'and snap_id in ('||trunc(p_begin_snap)||','||trunc(p_end_snap)||') '||
      'and begin_interval_time >= systimestamp-numtodsinterval(30,''DAY'') '||
      'order by snap_id';
    l_validation := em_query(l_target,l_sql,10);
    l_root := json_object_t.parse(l_validation);
    l_rows := l_root.get_array('Result');
    if l_rows is null or l_rows.get_size != 2 then
      return error_json('SNAPSHOT_NOT_FOUND',
        'Both snapshots must exist in the configured OEM target.');
    end if;
    l_row := treat(l_rows.get(0) as json_object_t);
    l_dbid := l_row.get_number('DBID');
    l_instance := l_row.get_number('INSTANCE_NUMBER');
    if treat(l_rows.get(1) as json_object_t).get_number('INSTANCE_NUMBER') != l_instance
       or treat(l_rows.get(1) as json_object_t).get_string('STARTUP_TIME')
          != l_row.get_string('STARTUP_TIME') then
      return error_json('SNAPSHOT_INSTANCE_MISMATCH',
        'Snapshots must belong to the same instance startup.');
    end if;

    l_sql := 'select output from table(dbms_workload_repository.awr_report_html('||
      trunc(l_dbid)||','||trunc(l_instance)||','||trunc(p_begin_snap)||','||
      trunc(p_end_snap)||'))';
    l_report_json := em_query(l_target,l_sql,-1);
    l_root := json_object_t.parse(l_report_json);
    l_rows := l_root.get_array('Result');
    dbms_lob.createtemporary(l_html,true);
    for i in 0..l_rows.get_size-1 loop
      l_row := treat(l_rows.get(i) as json_object_t);
      if l_row.has('OUTPUT') and not l_row.get('OUTPUT').is_null then
        dbms_lob.append(l_html,to_clob(l_row.get_string('OUTPUT')||chr(10)));
      else
        dbms_lob.append(l_html,to_clob(chr(10)));
      end if;
    end loop;

    -- Keep the full HTML in Oracle; send only bounded evidence to the LLM.
    l_analysis_evidence := collect_analysis_evidence(
      l_target,trunc(p_begin_snap),trunc(p_end_snap));

    begin
      l_llm_analysis := dbms_cloud_ai.generate(
        prompt => to_clob(
          '你是資深 Oracle DBA。請只根據下列 AWR evidence，以繁體中文輸出：'||
          '執行摘要、P1/P2/P3 主要發現、Top Wait Events、Top SQL 與 Plan、'||
          '唯讀驗證建議。每項結論引用實際 metric、event、SQL_ID、'||
          'PLAN_HASH_VALUE 或 plan operation。分清事實與假設，不得捏造根因，'||
          '不得建議直接執行變更。'||chr(10)||l_analysis_evidence),
        profile_name => c_analysis_profile,
        action => 'chat');
      l_analysis_status := 'READY';
    exception when others then
      l_analysis_status := 'FAILED';
      l_llm_analysis := to_clob('DeepSeek analysis failed: '||substr(sqlerrm,1,1000));
    end;

    insert into dba_assist_em_awr_reports(
      report_id,em_target_name,db_name,dbid,instance_number,begin_snap,end_snap,
      report_status,report_html,report_bytes,requested_by,expires_at)
    values(
      l_report_id,l_target,l_target,l_dbid,l_instance,trunc(p_begin_snap),
      trunc(p_end_snap),'READY',l_html,dbms_lob.getlength(l_html),
      coalesce(sys_context('APEX$SESSION','APP_USER'),
               sys_context('USERENV','SESSION_USER')),
      systimestamp+interval '7' day);
    commit;

    l_result.put('status','READY');
    l_result.put('report_id',l_report_id);
    l_result.put('source_system','ORACLE_ENTERPRISE_MANAGER_REST');
    l_result.put('em_target_name',l_target);
    l_result.put('db_name',l_target);
    l_result.put('dbid',l_dbid);
    l_result.put('instance_number',l_instance);
    l_result.put('begin_snap',trunc(p_begin_snap));
    l_result.put('end_snap',trunc(p_end_snap));
    l_result.put('report_format','HTML');
    l_result.put('report_bytes',dbms_lob.getlength(l_html));
    l_result.put('analysis_evidence',l_analysis_evidence);
    l_result.put('analysis_profile',c_analysis_profile);
    l_result.put('analysis_status',l_analysis_status);
    l_result.put('deepseek_analysis',l_llm_analysis);
    l_result.put('analysis_instruction',
      'Use only ANALYSIS_EVIDENCE. Separate facts from hypotheses, prioritize findings, and recommend read-only verification. Do not claim root cause without evidence and do not execute remediation.');
    l_result.put('next_action','Open or download the report from Application 105.');
    return l_result.to_clob();
  exception when others then
    rollback;
    return error_json('EM_AWR_GENERATION_FAILED',sqlerrm);
  end;

  function get_report_html(p_report_id in varchar2) return clob is l_html clob;
  begin
    select report_html into l_html from dba_assist_em_awr_reports
    where report_id=upper(trim(p_report_id)) and report_status='READY'
      and expires_at>systimestamp;
    return l_html;
  end;
end ai_pkg_apex_em_awr;
/
show errors package &APP_SCHEMA..ai_pkg_apex_em_awr
show errors package body &APP_SCHEMA..ai_pkg_apex_em_awr

create or replace function &APP_SCHEMA..ai_fn_apex_em_snapshot_list(
  p_target_name in varchar2,
  p_hours_back in number) return clob authid definer as
begin
  return ai_pkg_apex_em_awr.list_snapshots(p_target_name,p_hours_back);
end;
/

create or replace function &APP_SCHEMA..ai_fn_apex_em_awr_generate(
  p_target_name in varchar2,
  p_begin_snap in number,p_end_snap in number,
  p_awr_generate_confirmed in varchar2) return clob authid definer as
begin
  return ai_pkg_apex_em_awr.generate_report(
    p_target_name,p_begin_snap,p_end_snap,p_awr_generate_confirmed);
end;
/

create or replace function &APP_SCHEMA..ai_fn_apex_em_awr_collector(
  p_request in varchar2) return clob authid definer as
  l_request varchar2(32767) := nvl(p_request,'');
  l_upper varchar2(32767) := upper(nvl(p_request,''));
  l_begin_snap number;
  l_end_snap number;
  l_hours number := 24;
  l_value varchar2(100);
  l_target varchar2(128);
begin
  if regexp_like(l_upper,'LIST_TARGETS|列出.*(資料庫|DATABASE)|可用.*(資料庫|DATABASE)') then
    return ai_pkg_apex_em_awr.list_targets;
  end if;

  l_target := regexp_substr(l_request,
    'TARGET[[:space:]]*=[[:space:]]*([[:alnum:]_.-]+)',1,1,'i',1);
  if l_target is null then
    return ai_pkg_apex_em_awr.list_targets;
  end if;

  if regexp_like(l_upper,
       'AWR_GENERATE_CONFIRMED[[:space:]]*=[[:space:]]*YES') then
    l_value := regexp_substr(l_upper,
      'BEGIN_SNAP[[:space:]]*=[[:space:]]*([0-9]+)',1,1,null,1);
    if l_value is not null then l_begin_snap := to_number(l_value); end if;
    l_value := regexp_substr(l_upper,
      'END_SNAP[[:space:]]*=[[:space:]]*([0-9]+)',1,1,null,1);
    if l_value is not null then l_end_snap := to_number(l_value); end if;
    return ai_pkg_apex_em_awr.generate_report(
      l_target,l_begin_snap,l_end_snap,'YES');
  end if;

  l_value := regexp_substr(l_upper,
    '([0-9]+)[[:space:]]*(HOURS?|小時)',1,1,null,1);
  if l_value is not null then
    l_hours := to_number(l_value);
  else
    l_value := regexp_substr(l_upper,
      '([0-9]+)[[:space:]]*(DAYS?|天)',1,1,null,1);
    if l_value is not null then l_hours := to_number(l_value)*24; end if;
  end if;
  return ai_pkg_apex_em_awr.list_snapshots(l_target,l_hours);
exception when others then
  return to_clob('{"status":"ERROR","error_code":"AWR_COLLECTOR_FAILED","message":"'||
    replace(substr(sqlerrm,1,1000),'"','''')||'"}');
end;
/

prompt === 6. SELECT AI AGENT TEAM (_NEW) ===
create or replace procedure &APP_SCHEMA..ai_proc_register_apex_em_awr_new
authid definer as
begin
  begin dbms_cloud_ai_agent.drop_team('AI_TEAM_APEX_EM_AWR_NEW',force=>true);
  exception when others then null; end;
  begin dbms_cloud_ai_agent.drop_agent('AI_AGENT_APEX_EM_AWR_NEW',force=>true);
  exception when others then null; end;
  begin dbms_cloud_ai_agent.drop_task('AI_TASK_APEX_EM_AWR_NEW',force=>true);
  exception when others then null; end;
  begin dbms_cloud_ai_agent.drop_tool('AI_TOOL_APEX_EM_SNAPSHOT_LIST_NEW',force=>true);
  exception when others then null; end;
  begin dbms_cloud_ai_agent.drop_tool('AI_TOOL_APEX_EM_AWR_GENERATE_NEW',force=>true);
  exception when others then null; end;
  begin dbms_cloud_ai_agent.drop_tool('AI_TOOL_APEX_EM_AWR_COLLECTOR_NEW',force=>true);
  exception when others then null; end;
  begin dbms_cloud_ai_agent.drop_tool('AI_TOOL_APEX_EM_AWR_REPORT_NEW',force=>true);
  exception when others then null; end;

  -- Existing customer Ask Oracle profile is reused; no LLM endpoint is created here.


  dbms_cloud_ai_agent.create_tool(
    tool_name=>'AI_TOOL_APEX_EM_AWR_REPORT_NEW',
    attributes=>q'~{
      "function":"AI_FN_APEX_EM_AWR_COLLECTOR",
      "instruction":"This is the only AWR tool. Pass the complete unchanged user request in P_REQUEST. Without AWR_GENERATE_CONFIRMED=YES it returns the requested snapshot list, defaulting to 24 hours. With explicit BEGIN_SNAP, END_SNAP and AWR_GENERATE_CONFIRMED=YES it generates the HTML report and returns bounded analysis evidence. Call it exactly once."
    }~',description=>'Single-call Application 105 AWR workflow collector.');

  dbms_cloud_ai_agent.create_task(
    task_name=>'AI_TASK_APEX_EM_AWR_NEW',
    attributes=>q'~{
      "instruction":"Application 105 AWR workflow. Call AI_TOOL_APEX_EM_AWR_REPORT_NEW exactly once with P_REQUEST={query}. This is the only allowed tool; copy its name exactly. For snapshot results, display every row and ask for BEGIN_SNAP, END_SNAP and AWR_GENERATE_CONFIRMED=YES. For READY report results, summarize all ANALYSIS_EVIDENCE in Traditional Chinese, cite metrics, wait events, SQL_ID, PLAN_HASH_VALUE and plan operations, separate facts from hypotheses, and rank read-only recommendations P1/P2/P3. Never invent evidence or execute remediation.",
      "tools":["AI_TOOL_APEX_EM_AWR_REPORT_NEW"],
      "enable_human_tool":"false"
    }~',description=>'Application 105 APEX-based two-stage AWR workflow.');

  dbms_cloud_ai_agent.create_agent(
    agent_name=>'AI_AGENT_APEX_EM_AWR_NEW',
    attributes=>q'~{
      "profile_name":"&AI_PROFILE",
      "role":"Application 105 AWR tool router. Call only the exact supplied tool and present its snapshot rows or DeepSeek analysis.",
      "enable_human_tool":"false"
    }~',description=>'Application 105 APEX-based AWR agent.');

  dbms_cloud_ai_agent.create_team(
    team_name=>'AI_TEAM_APEX_EM_AWR_NEW',
    attributes=>q'~{
      "agents":[{"name":"AI_AGENT_APEX_EM_AWR_NEW","task":"AI_TASK_APEX_EM_AWR_NEW"}],
      "process":"sequential"
    }~',description=>'Application 105 APEX-based AWR team NEW.');
end;
/
begin &APP_SCHEMA..ai_proc_register_apex_em_awr_new; end;
/
drop procedure &APP_SCHEMA..ai_proc_register_apex_em_awr_new;

commit;

prompt === 7. VERIFICATION ===
column object_name format a42
column object_type format a18
select object_name,object_type,status from dba_objects
where owner=upper('&APP_SCHEMA') and object_name in (
  'AI_TBL_APEX_EM_TARGET_MAPPING','AI_VW_APEX_EM_TARGETS',
  'DBA_ASSIST_EM_AWR_REPORTS','V_DBA_ASSIST_EM_AWR_REPORTS',
  'AI_PKG_APEX_EM_AWR','AI_FN_APEX_EM_SNAPSHOT_LIST',
  'AI_FN_APEX_EM_AWR_GENERATE','AI_FN_APEX_EM_AWR_COLLECTOR')
order by object_type,object_name;

select agent_team_name,status from dba_ai_agent_teams
where owner=upper('&APP_SCHEMA') and agent_team_name='AI_TEAM_APEX_EM_AWR_NEW';
select agent_name,status from dba_ai_agents
where owner=upper('&APP_SCHEMA') and agent_name='AI_AGENT_APEX_EM_AWR_NEW';
select task_name,status from dba_ai_agent_tasks
where owner=upper('&APP_SCHEMA') and task_name='AI_TASK_APEX_EM_AWR_NEW';
select tool_name,status from dba_ai_agent_tools
where owner=upper('&APP_SCHEMA') and tool_name='AI_TOOL_APEX_EM_AWR_REPORT_NEW'
order by tool_name;

prompt Installation complete. Configure Application 105 to use AI_TEAM_APEX_EM_AWR_NEW.
undefine EM_PASSWORD
exit success


prompt === Reconnect as the Application Schema ===
accept APP_CONNECT char prompt 'Application schema connect string (user/password@service): ' hide
connect &&APP_CONNECT
whenever sqlerror exit sql.sqlcode rollback


prompt ================================================================================
prompt Installing: 11_16_apex_em_target_mapping.sql
prompt ================================================================================
--------------------------------------------------------------------------------
-- Portable Application 105 EM target mapping. No database name is hardcoded.
-- Populate one row per Enterprise Manager oracle_database target.
--------------------------------------------------------------------------------
set define on
begin
  execute immediate q'[
    create table &&APP_SCHEMA.ai_tbl_apex_em_target_mapping (
      em_target_name       varchar2(128) primary key,
      em_target_type       varchar2(128) default 'oracle_database' not null,
      db_display_name      varchar2(256) not null,
      em_db_credential_set varchar2(128) not null,
      enabled              varchar2(1) default 'Y' not null,
      created_at           timestamp with time zone default systimestamp not null,
      constraint ck_apex_em_target_enabled check (enabled in ('Y','N')),
      constraint ck_apex_em_target_type check (em_target_type='oracle_database')
    )
  ]';
exception when others then
  if sqlcode != -955 then raise; end if;
end;
/

create or replace view &&APP_SCHEMA.ai_vw_apex_em_targets as
select em_target_name, em_target_type, db_display_name,
       em_db_credential_set, enabled
from &&APP_SCHEMA.ai_tbl_apex_em_target_mapping
where enabled='Y';

comment on table &&APP_SCHEMA.ai_tbl_apex_em_target_mapping is
  'Application 105 portable EM target allowlist; populate per customer deployment.';

-- Example only; do not run unless these are real customer targets:
-- insert into &&APP_SCHEMA.ai_tbl_apex_em_target_mapping
--   (em_target_name, db_display_name, em_db_credential_set)
-- values ('customer_db_target', 'Customer Database', 'NC_CUSTOMER_DB');
-- commit;

-- Customer targets are discovered from AI_VW_EM_TARGETS and registered through
-- the APEX administration page.  This installer intentionally seeds no target.


prompt ================================================================================
prompt Installing: 12_17_apex_em_target_admin.sql
prompt ================================================================================
--------------------------------------------------------------------------------
-- APEX EM Target Administration API
--
-- This is deliberately separate from the AWR user flow.  It permits only
-- allowlisted APEX administrators to register an OEM database target, performs
-- a read-only remote health check, and enables the target only on success.
-- No database, OMS, or credential password is accepted or stored here.
-- Prerequisite: install the multi-target AI_PKG_APEX_EM_AWR runtime.
--------------------------------------------------------------------------------
set define on
set serveroutput on size unlimited

begin
  execute immediate q'[
    create table &&APP_SCHEMA.ai_tbl_apex_em_target_admins (
      app_user    varchar2(255) primary key,
      enabled     varchar2(1) default 'Y' not null,
      created_at  timestamp with time zone default systimestamp not null,
      constraint ck_apex_em_target_admin_enabled check (enabled in ('Y','N'))
    )]';
exception when others then if sqlcode != -955 then raise; end if;
end;
/

begin
  execute immediate q'[
    create table &&APP_SCHEMA.ai_tbl_apex_em_target_audit (
      audit_id             number generated always as identity primary key,
      action               varchar2(30) not null,
      em_target_name       varchar2(128) not null,
      db_display_name      varchar2(256),
      credential_set_name  varchar2(128),
      requested_by         varchar2(255) not null,
      requested_at         timestamp with time zone default systimestamp not null,
      outcome              varchar2(20) not null,
      detail               varchar2(4000)
    )]';
exception when others then if sqlcode != -955 then raise; end if;
end;
/

create or replace package &&APP_SCHEMA.ai_pkg_apex_em_target_admin authid definer as
  function list_targets return clob;
  function discover_targets return clob;
  function save_and_verify(
    p_target_name       in varchar2,
    p_display_name      in varchar2,
    p_credential_set    in varchar2
  ) return clob;
  function set_enabled(p_target_name in varchar2, p_enabled in varchar2) return clob;
end ai_pkg_apex_em_target_admin;
/

create or replace package body &&APP_SCHEMA.ai_pkg_apex_em_target_admin as
  procedure assert_admin is
    l_user varchar2(255) := upper(nvl(sys_context('APEX$SESSION','APP_USER'),
                                     sys_context('USERENV','SESSION_USER')));
    l_count number;
  begin
    select count(*) into l_count
    from ai_tbl_apex_em_target_admins
    where app_user = l_user and enabled = 'Y';
    if l_count != 1 then
      raise_application_error(-20560, 'EM Target administration is restricted to approved APEX administrators.');
    end if;
  end;

  function app_user return varchar2 is
  begin
    return upper(nvl(sys_context('APEX$SESSION','APP_USER'), sys_context('USERENV','SESSION_USER')));
  end;

  procedure validate_input(p_target varchar2, p_display varchar2, p_credential varchar2) is
  begin
    if not regexp_like(trim(p_target), '^[A-Za-z0-9_.:-]{1,128}$') then
      raise_application_error(-20561, 'Target name may contain only letters, numbers, dot, underscore, colon, and hyphen.');
    end if;
    if trim(p_display) is null or length(trim(p_display)) > 256 then
      raise_application_error(-20562, 'Display name is required and must be at most 256 characters.');
    end if;
    if not regexp_like(trim(p_credential), '^[A-Za-z0-9_.:-]{1,128}$') then
      raise_application_error(-20563, 'Credential set name is invalid. Enter the existing Enterprise Manager credential-set name only.');
    end if;
  end;

  procedure audit(p_action varchar2, p_target varchar2, p_display varchar2,
                  p_credential varchar2, p_outcome varchar2, p_detail varchar2) is
    l_actor varchar2(255) := app_user;
  begin
    insert into ai_tbl_apex_em_target_audit(
      action, em_target_name, db_display_name, credential_set_name,
      requested_by, outcome, detail)
    values (p_action, trim(p_target), trim(p_display), trim(p_credential),
            l_actor, p_outcome, substr(p_detail, 1, 4000));
  end;

  function result_json(p_status varchar2, p_message varchar2, p_target varchar2) return clob is
    l_json json_object_t := json_object_t();
  begin
    l_json.put('status', p_status);
    l_json.put('message', p_message);
    l_json.put('target', trim(p_target));
    return l_json.to_clob();
  end;

  function list_targets return clob is
    l_root json_object_t := json_object_t();
    l_rows json_array_t := json_array_t();
    l_row json_object_t;
  begin
    assert_admin;
    for r in (select em_target_name, db_display_name, em_db_credential_set, enabled, created_at
                from ai_tbl_apex_em_target_mapping order by db_display_name) loop
      l_row := json_object_t();
      l_row.put('target', r.em_target_name);
      l_row.put('display_name', r.db_display_name);
      l_row.put('credential_set', r.em_db_credential_set);
      l_row.put('enabled', r.enabled);
      l_row.put('created_at', to_char(r.created_at, 'YYYY-MM-DD HH24:MI:SS TZH:TZM'));
      l_rows.append(l_row);
    end loop;
    l_root.put('status','READY'); l_root.put('targets',l_rows);
    return l_root.to_clob();
  end;

  function discover_targets return clob is
    l_root json_object_t := json_object_t();
    l_rows json_array_t := json_array_t();
    l_row json_object_t;
  begin
    assert_admin;
    for r in (
      select e.target_name, e.target_type
      from ai_vw_em_targets e
      -- OEM Execute SQL works on an individual oracle_database target.
      -- A rac_database is a cluster aggregate and returns "Target not found"
      -- when passed to the Execute SQL endpoint; its instance targets are
      -- discovered separately as oracle_database rows.
      where e.target_type = 'oracle_database'
        and not exists (
          select 1 from ai_tbl_apex_em_target_mapping m
          where upper(m.em_target_name)=upper(e.target_name))
      order by e.target_name
    ) loop
      l_row:=json_object_t();
      l_row.put('target',r.target_name);
      l_row.put('target_type',r.target_type);
      l_rows.append(l_row);
    end loop;
    l_root.put('status','READY');l_root.put('targets',l_rows);
    return l_root.to_clob();
  end;

  function save_and_verify(p_target_name varchar2, p_display_name varchar2,
                           p_credential_set varchar2) return clob is
    -- OEM target names are case-sensitive. Preserve the exact spelling
    -- returned by discovery; upper-casing it makes OEM REST return 404/500
    -- "Target not found" even though the repository row exists.
    l_target varchar2(128) := trim(p_target_name);
    l_health clob;
    l_error varchar2(4000);
  begin
    assert_admin;
    validate_input(l_target, p_display_name, p_credential_set);
    declare
      l_count pls_integer;
    begin
      select count(*) into l_count
        from ai_vw_em_targets
       where upper(target_name)=l_target
         and target_type='oracle_database';
      if l_count != 1 then
        raise_application_error(-20568,
          'Select an Oracle Database instance target discovered from Enterprise Manager. RAC aggregate targets cannot execute database SQL.');
      end if;
    end;
    -- Keep the row uncommitted while testing.  The AWR runtime can see it in
    -- this session, but other sessions cannot use it before verification ends.
    merge into ai_tbl_apex_em_target_mapping t
    using (select l_target target_name, trim(p_display_name) display_name,
                  trim(p_credential_set) credential_name from dual) s
    on (t.em_target_name = s.target_name)
    when matched then update set t.db_display_name=s.display_name,
                                 t.em_db_credential_set=s.credential_name,
                                 t.enabled='Y'
    when not matched then insert (em_target_name, db_display_name, em_db_credential_set, enabled)
      values (s.target_name, s.display_name, s.credential_name, 'Y');

    l_health := ai_pkg_apex_em_awr.health_check(l_target);
    if not json_object_t.parse(l_health).has('Result')
       and not json_object_t.parse(l_health).has('RESULT') then
      raise_application_error(-20564, 'OEM target health check did not return database evidence: ' || dbms_lob.substr(l_health, 500, 1));
    end if;
    audit('SAVE_AND_VERIFY',l_target,p_display_name,p_credential_set,'READY',
          'Remote read-only health check succeeded.');
    commit;
    return result_json('READY','Target was verified through Enterprise Manager and enabled for AWR and Alert Log.',l_target);
  exception when others then
    l_error := sqlerrm;
    rollback;
    -- Failure is recorded independently; it never leaves a target enabled.
    begin
      audit('SAVE_AND_VERIFY',l_target,p_display_name,p_credential_set,'FAILED',l_error);
      commit;
    exception when others then rollback; end;
    return result_json(
      'ERROR',
      case
        when instr(l_error, 'ORA-20568') > 0 then
          '請選擇 Enterprise Manager 動態發現的 Oracle Database instance Target；RAC aggregate Target 無法執行資料庫 SQL。'
        when instr(l_error, 'Target not found') > 0 then
          'Enterprise Manager 找不到所選資料庫 instance Target。請重新整理清單後再試。'
        else
          '驗證失敗。請確認 EM Credential Set 已建立、已套用到所選 database instance，且具備唯讀查詢權限。詳細錯誤已寫入稽核紀錄。'
      end,
      l_target
    );
  end;

  function set_enabled(p_target_name varchar2, p_enabled varchar2) return clob is
    l_target varchar2(128) := trim(p_target_name);
    l_enabled varchar2(1) := upper(trim(p_enabled));
  begin
    assert_admin;
    if l_enabled not in ('Y','N') then
      raise_application_error(-20565,'Enabled must be Y or N.');
    end if;
    update ai_tbl_apex_em_target_mapping set enabled=l_enabled where em_target_name=l_target;
    if sql%rowcount != 1 then raise_application_error(-20566,'Target does not exist.'); end if;
    audit(case when l_enabled='Y' then 'ENABLE' else 'DISABLE' end,
          l_target,null,null,'READY','Changed enabled state.');
    commit;
    return result_json('READY',case when l_enabled='Y' then 'Target enabled.' else 'Target disabled.' end,l_target);
  exception when others then
    rollback;
    return result_json('ERROR',sqlerrm,l_target);
  end;
end ai_pkg_apex_em_target_admin;
/
show errors

-- Bootstrap deliberately requires an explicit named APEX account.  Do not
-- grant all workspace users by default.  Example:
-- insert into &&APP_SCHEMA.ai_tbl_apex_em_target_admins(app_user) values ('DBA_ADMIN');
-- commit;


prompt ================================================================================
prompt Installing: 13_bind_existing_ask_oracle_profile.sql
prompt ================================================================================
set serveroutput on
declare l_count number;
begin
  select count(*) into l_count from user_cloud_ai_profiles
   where profile_name='&&ASK_ORACLE_PROFILE' and status='ENABLED';
  if l_count<>1 then raise_application_error(-20003,'Existing Ask Oracle profile &&ASK_ORACLE_PROFILE is not ENABLED'); end if;
end;
/
begin
  begin dbms_cloud_ai_agent.drop_agent('AI_AGENT_APEX_EM_AWR_NEM3_FIXED',force=>true); exception when others then null; end;
  begin dbms_cloud_ai_agent.drop_agent('AI_AGENT_APEX_EM_AWR_CUSTOMER_PROFILE',force=>true); exception when others then null; end;
  dbms_cloud_ai_agent.create_agent(
    agent_name=>'AI_AGENT_APEX_EM_AWR_NEM3_FIXED',
    attributes=>q'~{"profile_name":"&&ASK_ORACLE_PROFILE","role":"Oracle EM AWR assistant using governed database tools.","enable_human_tool":"true"}~');
  dbms_cloud_ai_agent.create_agent(
    agent_name=>'AI_AGENT_APEX_EM_AWR_CUSTOMER_PROFILE',
    attributes=>q'~{"profile_name":"&&ASK_ORACLE_PROFILE","role":"Oracle EM AWR assistant using governed database tools.","enable_human_tool":"true"}~');
end;
/
merge into ai_tbl_apex_em_target_admins d using(select '&&INITIAL_APEX_ADMIN' app_user from dual)s
on(d.app_user=s.app_user) when matched then update set d.enabled='Y'
when not matched then insert(app_user,enabled) values(s.app_user,'Y');
commit;


prompt ================================================================================
prompt Installing: 14_install_awr_chat_download_analysis.sql
prompt ================================================================================
-- Application 105: complete the Select AI Agent AWR conversation.
-- Adds a real HTML report download URL and QUICK/DEEP analysis tools.
-- APEX/PLSQL/ORDS only; does not depend on the separate Python application.

set define on
set serveroutput on size unlimited

create or replace function &&APP_SCHEMA.ai_fn_apex_em_awr_download(
  p_report_id in varchar2
) return clob authid definer as
  l_id    varchar2(32) := upper(trim(p_report_id));
  l_actor varchar2(128) := upper(coalesce(v('APP_USER'), sys_context('USERENV','SESSION_USER')));
  l_count number;
  l_out   json_object_t := json_object_t();
begin
  select count(*) into l_count
    from &&APP_SCHEMA.dba_assist_em_awr_reports
   where report_id = l_id
     and report_status = 'READY'
     and expires_at > systimestamp
     and upper(requested_by) = l_actor;
  if l_count != 1 then
    l_out.put('status','ERROR');
    l_out.put('message','找不到報告、報告已過期，或目前使用者無權下載。');
    return l_out.to_clob();
  end if;
  l_out.put('status','READY');
  l_out.put('report_id',l_id);
  l_out.put('download_url','/ords/&&ORDS_MODULE/awr/report/' || lower(l_id));
  l_out.put('label','下載 AWR HTML 報告');
  l_out.put('expires_in','依報告保存期限，最長 7 天');
  return l_out.to_clob();
end;
/

begin
  execute immediate q'~create table &&APP_SCHEMA.ai_tbl_awr_analysis_cache (
    report_id        varchar2(32) not null,
    analysis_mode    varchar2(10) not null,
    actor            varchar2(128) not null,
    profile_name     varchar2(128) not null,
    status           varchar2(20) not null,
    payload          clob,
    error_message    varchar2(4000),
    created_at       timestamp with time zone default systimestamp not null,
    completed_at     timestamp with time zone,
    elapsed_seconds  number,
    constraint ai_pk_awr_analysis_cache primary key (report_id, analysis_mode, actor),
    constraint ai_ck_awr_analysis_mode check (analysis_mode in ('QUICK','DEEP')),
    constraint ai_ck_awr_analysis_status check (status in ('RUNNING','COMPLETE','FAILED'))
  )~';
exception
  when others then
    if sqlcode != -955 then raise; end if;
end;
/

create or replace function &&APP_SCHEMA.ai_fn_apex_em_awr_analyze(
  p_report_id in varchar2, p_analysis_mode in varchar2
) return clob authid definer as
  pragma autonomous_transaction;
  l_id varchar2(32):=upper(trim(p_report_id));
  l_mode varchar2(20):=upper(trim(p_analysis_mode));
  l_force boolean:=false;
  l_actor varchar2(128):=upper(coalesce(v('APP_USER'),sys_context('USERENV','CLIENT_IDENTIFIER'),sys_context('USERENV','SESSION_USER')));
  l_profile constant varchar2(128):='&&ASK_ORACLE_PROFILE';
  l_target varchar2(128); l_b number; l_e number;
  l_payload clob;
  l_error varchar2(4000);
  l_started timestamp with time zone:=systimestamp;
  l_elapsed number;

  function decorate(p_payload clob, p_cached boolean) return clob is
    l_json json_object_t;
    l_answer clob;
  begin
    l_json:=json_object_t.parse(p_payload);
    l_json.put('cached',p_cached);
    l_json.put('analysis_mode',l_mode);
    if l_json.has('answer') then
      l_answer:=l_json.get_clob('answer');
      if p_cached then
        l_json.put('answer',to_clob('> 已載入先前完成的')||case when l_mode='DEEP' then '深度分析' else '初步分析' end||'，本次未重新使用模型。'||chr(10)||chr(10)||l_answer);
      else
        l_json.put('answer',to_clob('> 新分析已完成並保存；下次開啟相同報告可直接載入。')||chr(10)||chr(10)||l_answer);
      end if;
    end if;
    return l_json.to_clob();
  exception when others then
    return p_payload;
  end;
begin
  if l_mode in ('INITIAL_FORCE','QUICK_FORCE') then
    l_mode:='QUICK'; l_force:=true;
  elsif l_mode='DEEP_FORCE' then
    l_mode:='DEEP'; l_force:=true;
  elsif l_mode='INITIAL' then
    l_mode:='QUICK';
  end if;
  if l_mode not in ('QUICK','DEEP') then
    return to_clob('{"status":"ERROR","message":"分析模式必須是 INITIAL、QUICK 或 DEEP。"}');
  end if;

  select em_target_name,begin_snap,end_snap into l_target,l_b,l_e
    from dba_assist_em_awr_reports
   where report_id=l_id and report_status='READY'
     and expires_at>systimestamp
     and upper(requested_by)=l_actor;

  if not l_force then
    begin
      select payload into l_payload
        from ai_tbl_awr_analysis_cache
       where report_id=l_id and analysis_mode=l_mode and actor=l_actor
         and status='COMPLETE' and payload is not null;
      commit;
      return decorate(l_payload,true);
    exception when no_data_found then null;
    end;
  end if;

  merge into ai_tbl_awr_analysis_cache c
  using (select l_id report_id,l_mode analysis_mode,l_actor actor from dual) s
     on (c.report_id=s.report_id and c.analysis_mode=s.analysis_mode and c.actor=s.actor)
  when matched then update set c.profile_name=l_profile,c.status='RUNNING',c.payload=null,
    c.error_message=null,c.created_at=systimestamp,c.completed_at=null,c.elapsed_seconds=null
  when not matched then insert
    (report_id,analysis_mode,actor,profile_name,status,created_at)
    values (s.report_id,s.analysis_mode,s.actor,l_profile,'RUNNING',systimestamp);
  commit;

  if l_mode='QUICK' then
    l_payload:=ai_pkg_apex_em_awr_ai.ask_report(l_id,
      l_profile,
      to_clob('請進行初步分析，但使用與 AWR Analyzer 相同的完整證據與輸出架構：健康摘要、Top 10 等待事件、P1/P2/P3 關鍵發現、Top SQL 與 Plan Hash、結論及唯讀驗證步驟。聚焦 evidence 內的證據。證據不足時必須明確標示為推論；不得臆測資料庫版本或承諾改善百分比。驗證 SQL 必須使用本報告的實際 Snapshot 時間，或使用 bind 變數，不得寫死日期。'),'QUICK');
  else
    l_payload:=ai_pkg_apex_em_awr_ai.ask_report(l_id,
      l_profile,
      to_clob('請提供深入分析：整理負載、等待事件、Top SQL、執行計畫、可能原因、證據限制、驗證步驟與優先順序。每個原因必須區分「證據支持」與「需要驗證的推論」；不得臆測資料庫版本或提供沒有比較基礎的改善百分比。驗證 SQL 使用實際 Snapshot 時間或 bind 變數。'),'DEEP');
  end if;

  l_elapsed:=extract(day from (systimestamp-l_started))*86400+
             extract(hour from (systimestamp-l_started))*3600+
             extract(minute from (systimestamp-l_started))*60+
             extract(second from (systimestamp-l_started));
  update ai_tbl_awr_analysis_cache
     set status='COMPLETE',payload=l_payload,completed_at=systimestamp,elapsed_seconds=l_elapsed
   where report_id=l_id and analysis_mode=l_mode and actor=l_actor;
  commit;
  return decorate(l_payload,false);
exception when no_data_found then
  rollback;
  return to_clob('{"status":"ERROR","message":"找不到報告、報告已過期，或目前使用者無權分析。"}');
when others then
  l_error:=substr(sqlerrm,1,4000);
  begin
    update ai_tbl_awr_analysis_cache
       set status='FAILED',error_message=l_error,completed_at=systimestamp
     where report_id=l_id and analysis_mode=l_mode and actor=l_actor;
    commit;
  exception when others then rollback;
  end;
  raise;
end;
/

create or replace function &&APP_SCHEMA.ai_fn_apex_em_awr_analysis_dispatch(
  p_report_id in varchar2, p_analysis_mode in varchar2
) return clob authid definer as
  pragma autonomous_transaction;
  l_id varchar2(32):=upper(trim(p_report_id));
  l_mode varchar2(20):=upper(trim(p_analysis_mode));
  l_base_mode varchar2(10);
  l_actor varchar2(128):=upper(coalesce(v('APP_USER'),sys_context('USERENV','CLIENT_IDENTIFIER'),sys_context('USERENV','SESSION_USER')));
  l_result clob; l_error varchar2(4000);
  l_json json_object_t;
  l_profile varchar2(128); l_target varchar2(128);
  l_begin number; l_end number; l_elapsed number; l_completed varchar2(40);
begin
  l_base_mode:=case when l_mode in ('INITIAL','INITIAL_FORCE','QUICK_FORCE') then 'QUICK'
                    when l_mode='DEEP_FORCE' then 'DEEP' else l_mode end;
  if l_mode in ('INITIAL_FORCE','QUICK_FORCE','DEEP_FORCE') then
    delete from ai_tbl_awr_analysis_cache
     where report_id=l_id and analysis_mode=l_base_mode and actor=l_actor;
    commit;
  end if;
  l_result:=ai_fn_apex_em_awr_analyze(l_id,l_base_mode);
  begin
    select c.profile_name,c.elapsed_seconds,
           to_char(c.completed_at,'YYYY-MM-DD HH24:MI:SS TZH:TZM'),
           r.em_target_name,r.begin_snap,r.end_snap
      into l_profile,l_elapsed,l_completed,l_target,l_begin,l_end
      from ai_tbl_awr_analysis_cache c join dba_assist_em_awr_reports r
        on r.report_id=c.report_id
     where c.report_id=l_id and c.analysis_mode=l_base_mode and c.actor=l_actor;
    l_json:=json_object_t.parse(l_result);
    l_json.put('profile_name',l_profile); l_json.put('elapsed_seconds',l_elapsed);
    l_json.put('completed_at',l_completed); l_json.put('target',l_target);
    l_json.put('begin_snap',l_begin); l_json.put('end_snap',l_end);
    l_result:=l_json.to_clob();
  exception when others then null;
  end;
  return l_result;
end;
/

begin
  execute immediate q'~create table &&APP_SCHEMA.ai_tbl_awr_analysis_job (
    job_id          varchar2(32) primary key,
    report_id       varchar2(32) not null,
    analysis_mode   varchar2(10) not null,
    actor           varchar2(128) not null,
    status          varchar2(20) not null,
    result_payload  clob,
    error_message   varchar2(4000),
    created_at      timestamp with time zone default systimestamp not null,
    started_at      timestamp with time zone,
    completed_at    timestamp with time zone,
    constraint ai_ck_awr_job_mode check (analysis_mode in ('QUICK','DEEP')),
    constraint ai_ck_awr_job_status check (status in ('QUEUED','RUNNING','COMPLETE','FAILED'))
  )~';
exception when others then
  if sqlcode != -955 then raise; end if;
end;
/

create or replace procedure &&APP_SCHEMA.ai_pr_apex_em_awr_analysis_job(p_job_id in varchar2)
authid definer as
  pragma autonomous_transaction;
  l_id varchar2(32):=upper(trim(p_job_id));
  l_report varchar2(32); l_mode varchar2(10); l_actor varchar2(128);
  l_result clob;
begin
  select report_id,analysis_mode,actor into l_report,l_mode,l_actor
    from ai_tbl_awr_analysis_job where job_id=l_id for update;
  update ai_tbl_awr_analysis_job set status='RUNNING',started_at=systimestamp,
    error_message=null where job_id=l_id;
  commit;
  dbms_session.set_identifier(l_actor);
  l_result:=ai_fn_apex_em_awr_analysis_dispatch(l_report,l_mode||'_FORCE');
  update ai_tbl_awr_analysis_job set status='COMPLETE',result_payload=l_result,
    completed_at=systimestamp where job_id=l_id;
  commit;
exception when others then
  l_error:=substr(sqlerrm,1,4000);
  update ai_tbl_awr_analysis_job set status='FAILED',error_message=l_error,
    completed_at=systimestamp where job_id=l_id;
  commit;
end;
/

create or replace function &&APP_SCHEMA.ai_fn_apex_em_awr_analysis_submit(
  p_report_id in varchar2, p_analysis_mode in varchar2
) return clob authid definer as
  pragma autonomous_transaction;
  l_report varchar2(32):=upper(trim(p_report_id));
  l_mode varchar2(10):=upper(trim(p_analysis_mode));
  l_actor varchar2(128):=upper(coalesce(v('APP_USER'),sys_context('USERENV','CLIENT_IDENTIFIER'),sys_context('USERENV','SESSION_USER')));
  l_job varchar2(32):=rawtohex(sys_guid()); l_dummy number; l_out json_object_t:=json_object_t();
begin
  if l_mode='INITIAL' then l_mode:='QUICK'; end if;
  if l_mode not in ('QUICK','DEEP') then raise_application_error(-20001,'Invalid analysis mode'); end if;
  select 1 into l_dummy from dba_assist_em_awr_reports
   where report_id=l_report and report_status='READY' and expires_at>systimestamp
     and upper(requested_by)=l_actor;
  begin
    select job_id into l_job from ai_tbl_awr_analysis_job
     where report_id=l_report and analysis_mode=l_mode and actor=l_actor
       and status in ('QUEUED','RUNNING') and rownum=1;
  exception when no_data_found then
    l_job:=rawtohex(sys_guid());
    insert into ai_tbl_awr_analysis_job(job_id,report_id,analysis_mode,actor,status)
      values(l_job,l_report,l_mode,l_actor,'QUEUED');
    commit;
    dbms_scheduler.create_job(
      job_name=>'AI_AWR_'||substr(l_job,1,22), job_type=>'STORED_PROCEDURE',
      job_action=>'&&APP_SCHEMA.AI_PR_APEX_EM_AWR_ANALYSIS_JOB',
      number_of_arguments=>1, enabled=>false, auto_drop=>true);
    dbms_scheduler.set_job_argument_value('AI_AWR_'||substr(l_job,1,22),1,l_job);
    dbms_scheduler.enable('AI_AWR_'||substr(l_job,1,22));
  end;
  l_out.put('status','QUEUED'); l_out.put('job_id',l_job);
  l_out.put('message','分析已在背景開始，您可以留在聊天室繼續操作。');
  return l_out.to_clob();
exception when no_data_found then
  return to_clob('{"status":"ERROR","message":"找不到報告、報告已過期，或目前使用者無權分析。"}');
end;
/

create or replace function &&APP_SCHEMA.ai_fn_apex_em_awr_analysis_status(p_job_id in varchar2)
return clob authid definer as
  l_actor varchar2(128):=upper(coalesce(v('APP_USER'),sys_context('USERENV','CLIENT_IDENTIFIER'),sys_context('USERENV','SESSION_USER')));
  l_status varchar2(20); l_result clob; l_error varchar2(4000); l_out json_object_t:=json_object_t();
begin
  select status,result_payload,error_message into l_status,l_result,l_error
    from ai_tbl_awr_analysis_job where job_id=upper(trim(p_job_id)) and actor=l_actor;
  if l_status='COMPLETE' and l_result is not null then return l_result; end if;
  l_out.put('status',l_status); l_out.put('job_id',upper(trim(p_job_id)));
  if l_error is not null then l_out.put('message',l_error); end if;
  return l_out.to_clob();
exception when no_data_found then
  return to_clob('{"status":"ERROR","message":"找不到這個分析工作，或目前使用者無權查看。"}');
end;
/

begin
  ords.enable_schema(
    p_enabled             => true,
    p_schema              => '&&APP_SCHEMA',
    p_url_mapping_type    => 'BASE_PATH',
    p_url_mapping_pattern => '&&ORDS_MODULE',
    p_auto_rest_auth      => false);

  ords.define_module(
    p_module_name    => 'aipoc.awr.download',
    p_base_path      => '/awr/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED');

  ords.define_template(
    p_module_name => 'aipoc.awr.download',
    p_pattern     => 'report/:report_id');

  ords.define_handler(
    p_module_name => 'aipoc.awr.download',
    p_pattern     => 'report/:report_id',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~declare
  l_html clob;
  l_id varchar2(32) := upper(trim(:report_id));
  l_pos pls_integer := 1;
begin
  select report_html into l_html
    from &&APP_SCHEMA.dba_assist_em_awr_reports
   where report_id = l_id
     and report_status = 'READY'
     and expires_at > systimestamp;
  owa_util.mime_header('text/html; charset=UTF-8', false);
  htp.p('Content-Disposition: attachment; filename="AWR_' || lower(l_id) || '.html"');
  htp.p('Cache-Control: private, no-store');
  owa_util.http_header_close;
  while l_pos <= dbms_lob.getlength(l_html) loop
    htp.prn(dbms_lob.substr(l_html, 32000, l_pos));
    l_pos := l_pos + 32000;
  end loop;
exception
  when no_data_found then
    :status_code := 404;
    :content_type := 'application/json; charset=UTF-8';
    htp.prn('{"status":"ERROR","message":"Report not found or expired"}');
end;~');

  ords.define_template(
    p_module_name => 'aipoc.awr.download',
    p_pattern     => 'analysis/:report_id/:mode');

  ords.define_handler(
    p_module_name => 'aipoc.awr.download',
    p_pattern     => 'analysis/:report_id/:mode',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~declare
  l_result clob;
  l_pos    pls_integer := 1;
begin
  if upper(trim(:mode)) like '%\_FORCE' escape '\' then
    :status_code := 405;
    l_result := to_clob('{"status":"ERROR","message":"重新分析請使用 POST。"}');
  else
    l_result := ai_fn_apex_em_awr_analysis_dispatch(
      upper(trim(:report_id)), upper(trim(:mode)));
  end if;
  owa_util.mime_header('application/json; charset=UTF-8', false);
  htp.p('Cache-Control: private, no-store');
  owa_util.http_header_close;
  while l_pos <= dbms_lob.getlength(l_result) loop
    htp.prn(dbms_lob.substr(l_result, 8000, l_pos));
    l_pos := l_pos + 8000;
  end loop;
end;~');

  ords.define_handler(
    p_module_name => 'aipoc.awr.download',
    p_pattern     => 'analysis/:report_id/:mode',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~declare
  l_result clob; l_pos pls_integer := 1;
begin
  if upper(trim(:mode)) not like '%\_FORCE' escape '\' then
    :status_code := 400;
    l_result := to_clob('{"status":"ERROR","message":"POST 僅用於使用者主動重新分析。"}');
  else
    l_result := ai_fn_apex_em_awr_analysis_dispatch(
      upper(trim(:report_id)), upper(trim(:mode)));
  end if;
  owa_util.mime_header('application/json; charset=UTF-8', false);
  htp.p('Cache-Control: private, no-store'); owa_util.http_header_close;
  while l_pos <= dbms_lob.getlength(l_result) loop
    htp.prn(dbms_lob.substr(l_result, 8000, l_pos)); l_pos := l_pos + 8000;
  end loop;
end;~');

  ords.define_template(
    p_module_name => 'aipoc.awr.download',
    p_pattern     => 'analysis-submit/:report_id/:mode');
  ords.define_handler(
    p_module_name => 'aipoc.awr.download',
    p_pattern     => 'analysis-submit/:report_id/:mode',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~declare l_result clob; l_pos pls_integer:=1;
begin
  l_result:=ai_fn_apex_em_awr_analysis_submit(upper(trim(:report_id)),upper(trim(:mode)));
  owa_util.mime_header('application/json; charset=UTF-8',false);
  htp.p('Cache-Control: private, no-store'); owa_util.http_header_close;
  while l_pos<=dbms_lob.getlength(l_result) loop
    htp.prn(dbms_lob.substr(l_result,8000,l_pos)); l_pos:=l_pos+8000;
  end loop;
end;~');

  ords.define_template(
    p_module_name => 'aipoc.awr.download',
    p_pattern     => 'analysis-status/:job_id');
  ords.define_handler(
    p_module_name => 'aipoc.awr.download',
    p_pattern     => 'analysis-status/:job_id',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~declare l_result clob; l_pos pls_integer:=1;
begin
  l_result:=ai_fn_apex_em_awr_analysis_status(upper(trim(:job_id)));
  owa_util.mime_header('application/json; charset=UTF-8',false);
  htp.p('Cache-Control: private, no-store'); owa_util.http_header_close;
  while l_pos<=dbms_lob.getlength(l_result) loop
    htp.prn(dbms_lob.substr(l_result,8000,l_pos)); l_pos:=l_pos+8000;
  end loop;
end;~');
  commit;
end;
/

begin
  dbms_cloud_ai_agent.drop_team('AI_TEAM_APEX_EM_AWR_CUSTOMER_PROFILE', force => true);
exception when others then null;
end;
/
begin
  dbms_cloud_ai_agent.drop_team('AI_TEAM_APEX_EM_AWR_NEM3_FIXED', force => true);
exception when others then null;
end;
/
begin
  dbms_cloud_ai_agent.drop_task('AI_TASK_APEX_EM_AWR_NEM3_FIXED', force => true);
exception when others then null;
end;
/
begin
  dbms_cloud_ai_agent.drop_tool('AI_TOOL_APEX_EM_AWR_DOWNLOAD', force => true);
exception when others then null;
end;
/
begin
  dbms_cloud_ai_agent.drop_tool('AI_TOOL_APEX_EM_AWR_ANALYZE', force => true);
exception when others then null;
end;
/

begin
  dbms_cloud_ai_agent.create_tool(
    tool_name => 'AI_TOOL_APEX_EM_AWR_DOWNLOAD',
    attributes => q'~{
      "function":"AI_FN_APEX_EM_AWR_DOWNLOAD",
      "instruction":"Return the real downloadable AWR HTML URL for an existing READY report owned by the current user. Required parameter: P_REPORT_ID. Call after report generation, or when the user asks to download the most recently generated report. Return the download_url as a clickable Markdown link. Never call this tool without a real report ID from the conversation."
    }~');

  dbms_cloud_ai_agent.create_tool(
    tool_name => 'AI_TOOL_APEX_EM_AWR_ANALYZE',
    attributes => q'~{
      "function":"AI_FN_APEX_EM_AWR_ANALYZE",
      "instruction":"Analyze an existing READY AWR report owned by the current user. Required parameters: P_REPORT_ID and P_ANALYSIS_MODE. Use INITIAL for 初步分析 and DEEP for 深度分析. Call exactly once only after the user selects an analysis mode. When status is READY, return the complete answer field without summarizing, shortening, rewording or omitting any section or table."
    }~');

  dbms_cloud_ai_agent.create_task(
    task_name => 'AI_TASK_APEX_EM_AWR_NEM3_FIXED',
    attributes => q'~{
      "instruction":"You are an Oracle Enterprise Manager AWR assistant. Understand natural-language intent with the model; never use keyword or regular-expression routing. For available databases call AI_TOOL_APEX_EM_TARGET_LIST. For snapshots call AI_TOOL_APEX_EM_SNAPSHOT_LIST with the target and 1-335 integer hours, and display every returned row including SNAP_ID. To generate a report require a known target, explicit begin and end snapshot IDs, and explicit confirmation; then call AI_TOOL_APEX_EM_AWR_GENERATE exactly once. When generation returns READY, immediately call AI_TOOL_APEX_EM_AWR_DOWNLOAD with that returned report ID and include a Markdown link formatted as [下載 AWR HTML 報告](download_url). When target, report format, snapshot range, confirmation, or analysis mode must be selected by the user, use the human tool; never return a tool value of None. On the next line ask whether the user wants 初步分析 or 深度分析. If the user chooses 初步分析, call AI_TOOL_APEX_EM_AWR_ANALYZE with the most recent report ID and P_ANALYSIS_MODE=INITIAL. If the user chooses 深度分析, call it with P_ANALYSIS_MODE=DEEP. For both analysis modes, present the tool's complete answer field verbatim; do not summarize, shorten, reword or omit its sections and tables. Preserve the most recent target, report ID and snapshot range across follow-up turns. If the user asks the difference: 初步分析較快並優先說明主要負載、異常與處理項目；深度分析會進一步說明可能原因、證據限制、驗證步驟與優先順序。Never invent tool results, report IDs, links, targets or snapshots. Use user-friendly Traditional Chinese outside the verbatim analysis result. User request: {query}",
      "tools":["AI_TOOL_APEX_EM_TARGET_LIST","AI_TOOL_APEX_EM_SNAPSHOT_LIST","AI_TOOL_APEX_EM_AWR_GENERATE","AI_TOOL_APEX_EM_AWR_DOWNLOAD","AI_TOOL_APEX_EM_AWR_ANALYZE"],
      "enable_human_tool":"true"
    }~',
    description => 'EM AWR conversation with native download and analysis follow-up.');

  dbms_cloud_ai_agent.create_team(
    team_name => 'AI_TEAM_APEX_EM_AWR_NEM3_FIXED',
    attributes => q'~{
      "agents":[{"name":"AI_AGENT_APEX_EM_AWR_NEM3_FIXED","task":"AI_TASK_APEX_EM_AWR_NEM3_FIXED"}],
      "process":"sequential"
    }~',
    description => 'AWR conversation team with download and analysis.');

  dbms_cloud_ai_agent.create_team(
    team_name => 'AI_TEAM_APEX_EM_AWR_CUSTOMER_PROFILE',
    attributes => q'~{
      "agents":[{"name":"AI_AGENT_APEX_EM_AWR_CUSTOMER_PROFILE","task":"AI_TASK_APEX_EM_AWR_NEM3_FIXED"}],
      "process":"sequential"
    }~',
    description => 'Gemini 3.5 AWR team with download and analysis.');
end;
/

select object_name, object_type, status
  from user_objects
 where object_name in ('AI_FN_APEX_EM_AWR_DOWNLOAD','AI_FN_APEX_EM_AWR_ANALYZE')
 order by object_name;

select tool_name, status
  from user_ai_agent_tools
 where tool_name in ('AI_TOOL_APEX_EM_AWR_DOWNLOAD','AI_TOOL_APEX_EM_AWR_ANALYZE')
 order by tool_name;

select agent_team_name, status
  from user_ai_agent_teams
 where agent_team_name in ('AI_TEAM_APEX_EM_AWR_CUSTOMER_PROFILE','AI_TEAM_APEX_EM_AWR_NEM3_FIXED')
 order by agent_team_name;


prompt ================================================================================
prompt Installing: 99_verify_as_app.sql
prompt ================================================================================
set serveroutput on
column object_name format a42
select object_type, object_name, status from user_objects
 where object_name like 'AI\_%' escape '\' or object_name like 'DBA_ASSIST\_%' escape '\'
 order by object_type, object_name;

select profile_name, status from user_cloud_ai_profiles
 where profile_name like 'AI_PROFILE_APEX_EM_AWR%';
select agent_team_name, status from user_ai_agent_teams
 where agent_team_name like 'AI_TEAM_APEX_EM_AWR%';
select module_name, uri_prefix from user_ords_modules
 where uri_prefix='&&ORDS_MODULE/';

declare
  l_invalid number;
begin
  select count(*) into l_invalid from user_objects where status='INVALID'
   and (object_name like 'AI\_%' escape '\' or object_name like 'DBA_ASSIST\_%' escape '\');
  if l_invalid>0 then raise_application_error(-20010,'Deployment has invalid objects: '||l_invalid); end if;
  dbms_output.put_line('Verification OK for &&APP_SCHEMA.');
end;
/



