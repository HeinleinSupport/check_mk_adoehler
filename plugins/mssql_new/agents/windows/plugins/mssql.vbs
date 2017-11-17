' -----------------------------------------------------------------------------
' Check_MK windows agent plugin to gather information from local MSSQL servers
'
' This plugin can be used to collect information of all running MSSQL server
' on the local system.
'
' The current implementation of the check uses the "trusted authentication"
' where no user/password needs to be created in the MSSQL server instance by
' default. It is only needed to grant the user as which the Check_MK windows
' agent service is running access to the MSSQL database.
'
' Another option is to create a mssql.ini file in MK_CONFDIR and write the
' credentials of a database user to it which shal be used for monitoring:
'
' [auth]
' type = db
' username = monitoring
' password = secret-pw
'
' The following sources are asked:
' 1. Registry - To gather a list of local MSSQL-Server instances
' 2. WMI - To check for the state of the MSSQL service
' 2. MSSQL-Servers via ADO/sqloledb connection to gather infos these infos:
'      a) list and sizes of available databases
'      b) counters of the database instance
'
' This check has been developed with MSSQL Server 2008 R2. It should work with
' older versions starting from at least MSSQL Server 2005.
' -----------------------------------------------------------------------------

Option Explicit

Dim WMI, FSO, SHO, items, objItem, prop, instVersion, registry
Dim sources, instances, instance, instance_id, instance_name
Dim cfg_dir, cfg_file, hostname, tcpport


Const HKLM = &H80000002

' Directory of all database instance names
Set instances = CreateObject("Scripting.Dictionary")
Set FSO = CreateObject("Scripting.FileSystemObject")
Set SHO = CreateObject("WScript.Shell")

hostname = SHO.ExpandEnvironmentStrings("%COMPUTERNAME%")
cfg_dir = SHO.ExpandEnvironmentStrings("%MK_CONFDIR%")

Sub addOutput(text)
    wscript.echo text
End Sub

Function readIniFile(path)
    Dim parsed : Set parsed = CreateObject("Scripting.Dictionary")
    If path <> "" Then
        Dim FH
        Set FH = FSO.OpenTextFile(path)
        Dim line, sec, pair
        Do Until FH.AtEndOfStream
            line = Trim(FH.ReadLine())
            If Left(line, 1) = "[" Then
                sec = Mid(line, 2, Len(line) - 2)
                Set parsed(sec) = CreateObject("Scripting.Dictionary")
            Else
                If line <> "" Then
                    pair = Split(line, "=")
                    If 1 = UBound(pair) Then
                        parsed(sec)(Trim(pair(0))) = Trim(pair(1))
                    End If
                End If
            End If
        Loop
        FH.Close
        Set FH = Nothing
    End If
    Set readIniFile = parsed
    Set parsed = Nothing
End Function

Set registry = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\default:StdRegProv")
Set sources = CreateObject("Scripting.Dictionary")

Dim service, i, version, edition, value_types, value_names, value_raw, cluster_name
Set WMI = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")

' Make sure that always all sections are present, even in case of an error. 
' Note: the section <<<mssql_instance>>> section shows the general state 
' of a database instance. If that section fails for an instance then all 
' other sections do not contain valid data anyway.
'
' Don't move this to another place. We need the steps above to decide whether or
' not this is a MSSQL server.
Dim sections, section_id
Set sections = CreateObject("Scripting.Dictionary")
sections.add "instance", "<<<mssql_instance:sep(124)>>>"
sections.add "databases", "<<<mssql_databases>>>"
sections.add "counters", "<<<mssql_counters>>>"
sections.add "instance_config", "<<<mssql_config>>>"
sections.add "tablespaces", "<<<mssql_tablespaces>>>"
sections.add "blocked_sessions", "<<<mssql_blocked_sessions>>>"
sections.add "backup", "<<<mssql_backup>>>"
sections.add "transactionlogs", "<<<mssql_transactionlogs>>>"
sections.add "datafiles", "<<<mssql_datafiles>>>"
sections.add "clusters", "<<<mssql_clusters>>>"
sections.add "highavailability", "<<<mssql_ha>>>"
sections.add "dbbackup", "<<<mssql_dbbackup>>>"
' Has been deprecated with 1.4.0i1. Keep this for nicer transition for some versions.
sections.add "versions", "<<<mssql_versions:sep(124)>>>"

For Each section_id In sections.Keys
    addOutput(sections(section_id))
Next

addOutput(sections("instance"))

'
' Gather instances on this host, store instance in instances and output version section for it
'

Dim regkeys, rk
regkeys = Array( "", "Wow6432Node") ' gather all instances, also 32bit ones on 64bit Windows

For Each rk In regkeys
    Do
        registry.EnumValues HKLM, "SOFTWARE\" & rk & "\Microsoft\Microsoft SQL Server\Instance Names\SQL", _
                                  value_names, value_types

        If Not IsArray(value_names) Then
            'addOutput("ERROR: Failed to gather SQL server instances: " & rk)
            'wscript.quit(1)
            Exit Do
        End If

        For i = LBound(value_names) To UBound(value_names)
            instance_id = value_names(i)

            registry.GetStringValue HKLM, "SOFTWARE\" & rk & "\Microsoft\Microsoft SQL Server\" & _
                                          "Instance Names\SQL", _
                                          instance_id, instance_name

            ' HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL10_50.MSSQLSERVER\MSSQLServer\CurrentVersion
            registry.GetStringValue HKLM, "SOFTWARE\" & rk & "\Microsoft\Microsoft SQL Server\" & _
                                          instance_name & "\MSSQLServer\CurrentVersion", _
                                          "CurrentVersion", version

            ' HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL10_50.MSSQLSERVER\Setup
            registry.GetStringValue HKLM, "SOFTWARE\" & rk & "\Microsoft\Microsoft SQL Server\" & _
                                          instance_name & "\Setup", _
                                          "Edition", edition

            ' Check whether or not this instance is clustered
            registry.GetStringValue HKLM, "SOFTWARE\" & rk & "\Microsoft\Microsoft SQL Server\" & _
                                          instance_name & "\Cluster", "ClusterName", cluster_name

            ' HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL10_50.MSSQLSERVER\MSSQLServer\SuperSocketNetLib\TCP\IPAll
            registry.GetStringValue HKLM, "SOFTWARE\" & rk & "\Microsoft\Microsoft SQL Server\" & _
                                          instance_name & "\MSSQLServer\SuperSocketNetLib\TCP\IPAll", _
                                          "tcpPort", tcpport

            If IsNull(cluster_name) Then
                cluster_name = ""

                ' In case of instance name "MSSQLSERVER" always use (local) as connect string
                If instance_id = "MSSQLSERVER" Then
                    sources.add instance_id, "(local)"
                Else
                    If isNull(tcpport) Then
                        sources.add instance_id, hostname & "\" & instance_id
                    Else
                        sources.add instance_id, hostname & "," & tcpport
                    End If
                End If
            Else
                ' In case the instance name is "MSSQLSERVER" always use the virtual server name
                If instance_id = "MSSQLSERVER" Then
                    sources.add instance_id, cluster_name
                Else
                    If isNull(tcpport) Then
                        sources.add instance_id, cluster_name & "\" & instance_id
                    Else
                        sources.add instance_id, cluster_name & "," & tcpport
                    End If
                End If
            End If

            addOutput(sections("instance"))
            addOutput("MSSQL_" & instance_id & "|config|" & version & "|" & edition & "|" & cluster_name)

            ' Only collect results for instances which services are currently running
            Set service = WMI.ExecQuery("SELECT State FROM Win32_Service " & _
                                  "WHERE Name = 'MSSQL$" & instance_id & "' AND State = 'Running'")
            If Not IsNull(service) Then
                instances.add instance_id, cluster_name
            End If
        Next
    Loop While False
Next

If InStr(1, version, "13") = 1 Then
    Dim section_ha
    section_ha = 1
End If

If instances.Count = 0 Then
    addOutput("ERROR: Failed to gather SQL server instances")
    wscript.quit(1)
End IF

Set service  = Nothing
Set WMI      = Nothing
Set registry = Nothing

Dim CONN, RS, CFG, AUTH

' Initialize database connection objects
Set CONN      = CreateObject("ADODB.Connection")
Set RS        = CreateObject("ADODB.Recordset")
CONN.Provider = "sqloledb"
' It's a local connection. 2 seconds should be enough!
CONN.ConnectionTimeout = 2
CONN.CommandTimeout = 10

' Loop all found server instances and connect to them
' In my tests only the connect using the "named instance" string worked
For Each instance_id In instances.Keys: Do ' Continue trick
    ' Is empty on standalone instances, and holds the name of the cluster on nodes
    cluster_name = instances(instance_id)

    ' Use either an instance specific config file named mssql_<instance-id>.ini
    ' or the default mysql.ini file.
    cfg_file = cfg_dir & "\mssql_" & instance_id & ".ini"
    If Not FSO.FileExists(cfg_file) Then
        cfg_file = cfg_dir & "\mssql.ini"
        If Not FSO.FileExists(cfg_file) Then
            cfg_file = ""
        End If
    End If

    Set CFG = readIniFile(cfg_file)
    If Not CFG.Exists("auth") Then
        Set AUTH = CreateObject("Scripting.Dictionary")
    Else
        Set AUTH = CFG("auth")
    End If
    
    ' At this place one could implement to use other authentication mechanism
    If Not AUTH.Exists("type") or AUTH("type") = "system" Then
        CONN.Properties("Integrated Security").Value = "SSPI"
    Else
        CONN.Properties("User ID").Value = AUTH("username")
        CONN.Properties("Password").Value = AUTH("password")
    End If

    CONN.Properties("Data Source").Value = sources(instance_id)

    ' Try to connect to the instance and catch the error when not able to connect
    ' Then add the instance to the agent output and skip over to the next instance
    ' in case the connection could not be established.
    On Error Resume Next
    CONN.Open
    On Error GoTo 0

    ' Collect eventual error messages of errors occured during connecting. Hopefully
    ' there is only on error in the list of errors.
    Dim error_msg
    If CONN.Errors.Count > 0 Then
        error_msg = CONN.Errors(0).Description
    End If
    Err.Clear

    addOutput(sections("instance"))
    ' 0 - closed
    ' 1 - open
    ' 2 - connecting
    ' 4 - executing a command
    ' 8 - rows are being fetched
    addOutput("MSSQL_" & instance_id & "|state|" & CONN.State & "|" & error_msg)

    ' adStateClosed = 0
    If CONN.State = 0 Then
        Exit Do
    End If

    ' Get counter data for the whole instance
    addOutput(sections("counters"))
    RS.Open "SELECT GETUTCDATE() as utc_date", CONN
    addOutput( "None utc_time None " & RS("utc_date") )
    RS.Close

    RS.Open "SELECT counter_name, object_name, instance_name, cntr_value " & _
            "FROM sys.dm_os_performance_counters " & _
            "WHERE object_name NOT LIKE '%Deprecated%'", CONN

    Dim objectName, counterName, instanceName, value
    Do While NOT RS.Eof
        objectName   = Replace(Replace(Trim(RS("object_name")), " ", "_"), "$", "_")
        counterName  = LCase(Replace(Trim(RS("counter_name")), " ", "_"))
        instanceName = Replace(Trim(RS("instance_name")), " ", "_")
        If instanceName = "" Then
            instanceName = "None"
        End If
        value        = Trim(RS("cntr_value"))
        addOutput( objectName & " " & counterName & " " & instanceName & " " & value )
        RS.MoveNext
    Loop
    RS.Close

    RS.Open "SELECT session_id, wait_duration_ms, wait_type, blocking_session_id " & _
            "FROM sys.dm_os_waiting_tasks " & _
            "WHERE blocking_session_id <> 0 ", CONN
    addOutput(sections("blocked_sessions"))
    Dim session_id, wait_duration_ms, wait_type, blocking_session_id
    Do While NOT RS.Eof
        session_id = Trim(RS("session_id"))
        wait_duration_ms = Trim(RS("wait_duration_ms"))
        wait_type = Trim(RS("wait_type"))
        blocking_session_id = Trim(RS("blocking_session_id"))
        addOutput(session_id & " " & wait_duration_ms & " " & wait_type & " " & blocking_session_id)
        RS.MoveNext
    Loop
    RS.Close

    addOutput(sections("instance_config"))
    ' instance configuration output
    RS.Open "EXEC sp_configure", CONN
    Dim confName, runValue, confValue
    Do While NOT RS.Eof
        confName   = LCase(Replace(Replace(Trim(RS("name")), " ", "_"), "$", "_"))
        confValue  = Replace(Replace(Trim(RS("config_value")), " ", "_"), "$", "_")
        runValue   = Replace(Replace(Trim(RS("run_value")), " ", "_"), "$", "_")
        addOutput( "MSSQL_" & instance_id & " " & confName & " " & confValue & " " & runValue )
        RS.MoveNext
    Loop
    RS.Close

    RS.Open "select name, is_disabled from sys.sql_logins where name = 'sa'", CONN
    addOutput( "MSSQL_" & instance_id & " sa_disabled " & RS("is_disabled") )
    RS.Close

    RS.Open "select name from sys.syslogins where sysadmin = '1' and name = 'Builtin\Administrators'", CONN
    continue = True
    Do While NOT RS.Eof
        addOutput( "MSSQL_" & instance_id & " builtin_sysadmin " & RS("name"))
        RS.MoveNext
        continue = False
    Loop
    If continue Then
        addOutput( "MSSQL_" & instance_id & " builtin_sysadmin disabled")
    End If
    RS.Close

    RS.Open "select name,is_trustworthy_on from sys.databases", CONN
    Do While NOT RS.Eof
        addOutput( "MSSQL_" & instance_id & " trustworthy_" & RS("name") & " " & RS("is_trustworthy_on") )
        RS.MoveNext
    Loop    
    RS.Close

    RS.Open "SELECT " &_
            "   db.name AS name," &_
            "   db.is_encrypted AS is_encrypted," &_
            "   dm.encryption_state AS encryption_state," &_
            "   dm.percent_complete," &_
            "   dm.key_algorithm," &_
            "   dm.key_length " &_
            "FROM" &_
            "   sys.databases db" &_
            "   LEFT OUTER JOIN sys.dm_database_encryption_keys dm " &_
            "ON db.database_id = dm.database_id;"
    Do While NOT RS.Eof
        addOutput( "MSSQL_" & instance_id & " encryption_" & RS("name") & " " & RS("is_encrypted") & " " & RS("encryption_state"))
        RS.MoveNext
    Loop
    RS.Close

    RS.Open "declare @AuditLevel int " &_
            " exec master..xp_instance_regread " &_
            " @rootkey='HKEY_LOCAL_MACHINE', " &_
            " @key='SOFTWARE\Microsoft\MSSQLServer\MSSQLServer', " &_
            " @value_name='AuditLevel', " &_
            " @value=@AuditLevel output " &_
            " select @AuditLevel as AuditLevel"
    addOutput( "MSSQL_" & instance_id & " audit_level " & RS("AuditLevel"))
    RS.Close

    ' First only read all databases in this instance and save it to the db names dict
    RS.Open "EXEC sp_databases", CONN
    Dim x, dbName, dbNames
    Set dbNames = CreateObject("Scripting.Dictionary")
    Do While NOT RS.Eof
        dbName = RS("DATABASE_NAME")
        dbNames.add dbName, ""
        RS.MoveNext
    Loop
    RS.Close

    For Each dbName in dbNames.Keys
        continue = True
        If dbName = "tempdb" Then continue = False End If
        If continue Then
            RS.Open "USE [" & dbName & "]", CONN
            RS.Open "select name, hasdbaccess from sys.sysusers where name = 'guest'", CONN
            addOutput( "MSSQL_" & instance_id & " guestaccess_" & Replace(dbName, " ", "_") & " " & RS("hasdbaccess") )
            RS.Close
        End If
    Next

    If section_ha = 1 Then
        RS.Open "SELECT " &_
	        " ar.replica_server_name," &_
	        " adc.database_name," &_
	        " ag.name AS ag_name," &_
	        " drs.is_local," &_
	        " drs.is_primary_replica," &_
	        " drs.synchronization_state_desc," &_
	        " drs.is_commit_participant," &_
	        " drs.synchronization_health_desc," &_
	        " drs.last_sent_time," &_
	        " drs.last_received_time," &_ 
	        " drs.last_hardened_time," &_
	        " drs.last_redone_time," &_
	        " drs.log_send_queue_size," &_
	        " drs.log_send_rate," &_
	        " drs.redo_queue_size," &_
	        " drs.redo_rate," &_
	        " drs.filestream_send_rate," &_
	        " drs.last_commit_time" &_
        " FROM sys.dm_hadr_database_replica_states AS drs" &_
        " INNER JOIN sys.availability_databases_cluster AS adc" &_
	        " ON drs.group_id = adc.group_id AND" &_
	        " drs.group_database_id = adc.group_database_id" &_
        " INNER JOIN sys.availability_groups AS ag" &_
	        " ON ag.group_id = drs.group_id" &_
        " INNER JOIN sys.availability_replicas AS ar" &_
	        " ON drs.group_id = ar.group_id AND" &_
	        " drs.replica_id = ar.replica_id" &_
        " WHERE drs.is_local = 1" &_
        " ORDER BY" &_
	        " ag.name," &_ 
	        " ar.replica_server_name," &_
	        " adc.database_name;", CONN
        addOutput(sections("highavailability"))

        Do While NOT RS.EoF
            'For Each x in RS.fields
            '    wscript.echo x.name & " " & x.value
            'Next
            addOutput("MSSQL_" & instance_id & " " & Replace(RS("database_name"), " ", "_") & " " & Replace(RS("ag_name"), " ", "_") & " " & _
                          RS("is_primary_replica") & " " & Replace(RS("synchronization_state_desc"), " ", "_") & " " & Replace(RS("synchronization_health_desc"), " ", "_"))
            RS.MoveNext
        Loop
        RS.Close
    End If

    RS.Open "SELECT " &_
		" CONVERT(CHAR(100), SERVERPROPERTY('Servername')) AS Server, " &_
		" msdb.dbo.backupset.database_name, " &_
		" msdb.dbo.backupset.backup_start_date, " &_
		" msdb.dbo.backupset.backup_finish_date, " &_
		" msdb.dbo.backupset.expiration_date, " &_
		" CASE msdb..backupset.type " &_
		" WHEN 'D' THEN 'Database' " &_
		" WHEN 'L' THEN 'Log' " &_
		" END AS backup_type, " &_
		" msdb.dbo.backupset.backup_size, " &_
		" msdb.dbo.backupmediafamily.logical_device_name, " &_
		" msdb.dbo.backupmediafamily.physical_device_name, " &_
		" msdb.dbo.backupset.name AS backupset_name, " &_
		" msdb.dbo.backupset.description " &_
		" FROM msdb.dbo.backupmediafamily " &_
		" INNER JOIN msdb.dbo.backupset ON msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id " &_
		" WHERE (CONVERT(datetime, msdb.dbo.backupset.backup_start_date, 102) >= GETDATE() - 2) AND msdb..backupset.type = 'D' " &_
		" ORDER BY " &_
		" msdb.dbo.backupset.database_name, " &_
		" msdb.dbo.backupset.backup_finish_date;", CONN
	addOutput(sections("dbbackup"))
	
    Do While NOT RS.EoF
        'For Each x in RS.fields
        '    wscript.echo x.name & " " & x.value
        'Next
        addOutput("MSSQL_" & instance_id & " " & Replace(RS("database_name"), " ", "_") & " " & Replace(RS("backup_start_date"), " ", "_") & " " & _
                  Replace(RS("backup_finish_date"), " ", "_") & " " & RS("backup_size") & " " & RS("backupset_name"))
        RS.MoveNext
    Loop	
	RS.Close
	
    ' Now gather the db size and unallocated space
    addOutput(sections("tablespaces"))
    Dim dbSize, unallocated, reserved, data, indexSize, unused, continue
    For Each dbName in dbNames.Keys
        ' Switch to other database and then ask for stats
        continue = True
        If dbName = "tempdb" Then continue = False End If
        If continue Then
            RS.Open "USE [" & dbName & "]", CONN
            ' sp_spaceused is a stored procedure which returns two selects
            ' which need to be looped
            RS.Open "EXEC sp_spaceused", CONN
            i = 0
            Do Until RS Is Nothing
                Do While NOT RS.Eof
                    'For Each x in RS.fields
                    '    wscript.echo x.name & " " & x.value
                    'Next
                    If i = 0 Then
                        ' Size of the current database in megabytes. database_size includes both data and log files.
                        dbSize      = Trim(RS("database_size"))
                        ' Space in the database that has not been reserved for database objects.
                        unallocated = Trim(RS("unallocated space"))
                    Elseif i = 1 Then
                        ' Total amount of space allocated by objects in the database.
                        reserved    = Trim(RS("reserved"))
                        ' Total amount of space used by data.
                        data        = Trim(RS("data"))
                        ' Total amount of space used by indexes.
                        indexSize   = Trim(RS("index_size"))
                        ' Total amount of space reserved for objects in the database, but not yet used.
                        unused      = Trim(RS("unused"))
                    End If
                    RS.MoveNext
                Loop
                Set RS = RS.NextRecordset
                i = i + 1
            Loop
            addOutput("MSSQL_" & instance_id & " " & Replace(dbName, " ", "_") & " " & dbSize & " " & _
                      unallocated & " " & reserved & " " & data & " " & indexSize & " " & unused)
            Set RS = CreateObject("ADODB.Recordset")
        End If
    Next

    ' Loop all databases to get the date of the last backup. Only show databases
    ' which have at least one backup
    Dim lastBackupDate, backup_type, is_primary_replica, replica_id, backup_machine_name
    addOutput(sections("backup"))
    For Each dbName in dbNames.Keys
        RS.Open "USE [" & dbName & "]", CONN
        RS.open "IF EXISTS (select 1 from sys.sysobjects where name = 'dm_hadr_database_replica_states') " & _
                "BEGIN " & _
                  "SELECT CONVERT(VARCHAR, DATEADD(s, DATEDIFF(s, '19700101', MAX(b.backup_finish_date)), '19700101'), 120) AS last_backup_date, " & _
                  "b.type, b.machine_name, " & _
                  "isnull(rep.is_primary_replica,0) as is_primary_replica, rep.is_local, isnull(convert(varchar(40), rep.replica_id), '') AS replica_id " & _
                  "FROM msdb.dbo.backupset b " & _
                  "LEFT OUTER JOIN sys.databases db ON b.database_name = db.name " & _
                  "LEFT OUTER JOIN sys.dm_hadr_database_replica_states rep ON db.database_id = rep.database_id " & _
                  "WHERE database_name = '" & dbName & "' " & _
				  "AND b.machine_name = '" & hostname & "' " & _
				  "AND (rep.is_local is null or rep.is_local = 1) " & _
				  "AND (rep.is_primary_replica is null or rep.is_primary_replica = 1) " & _
                  "GROUP BY type, rep.replica_id, rep.is_primary_replica, rep.is_local, b.database_name, b.machine_name, rep.synchronization_state, rep.synchronization_health " & _
                "END " & _
                "ELSE " & _
                 "BEGIN " & _
                  "SELECT CONVERT(VARCHAR, DATEADD(s, DATEDIFF(s, '19700101', MAX(backup_finish_date)), '19700101'), 120) AS last_backup_date," & _
                  "type, machine_name, " & _
                                                 "'1' as is_primary_replica, " &_
                                                 "'1' as is_local, " & _
                                                 "'' as replica_id " & _
                  "FROM msdb.dbo.backupset " & _
                  "WHERE database_name = '" & dbName & "' " & _
                  "GROUP BY type, machine_name " & _
                "END", CONN

        Do While Not RS.Eof
            lastBackupDate = Trim(RS("last_backup_date"))

            backup_type = Trim(RS("type"))
            If backup_type = "" Then
                backup_type = "-"
            End If

            replica_id = Trim(RS("replica_id"))
            is_primary_replica = Trim(RS("is_primary_replica"))
            backup_machine_name = Trim(RS("machine_name"))

            If lastBackupDate <> "" and (replica_id = "" or is_primary_replica = "1") AND hostname = backup_machine_name Then
                addOutput("MSSQL_" & instance_id & " " & Replace(dbName, " ", "_") & _
                          " " & lastBackupDate & " " & backup_type)
            End If
            RS.MoveNext
        Loop
        RS.Close
    Next

    ' Loop all databases to get the size of the transaction log
    addOutput(sections("transactionlogs"))
    For Each dbName in dbNames.Keys
       RS.Open "USE [" & dbName & "];", CONN
       RS.Open "SELECT name, physical_name," &_
                  "  cast(max_size/128 as bigint) as MaxSize," &_
                  "  cast(size/128 as bigint) as AllocatedSize," &_
                  "  cast(FILEPROPERTY (name, 'spaceused')/128 as bigint) as UsedSize," &_
                  "  case when max_size = '-1' then '1' else '0' end as Unlimited" &_
                  " FROM sys.database_files WHERE type_desc = 'LOG'", CONN
        Do While Not RS.Eof
            addOutput( instance_id & " " & Replace(dbName, " ", "_") & " " & Replace(RS("name"), " ", "_") & _
                      " " & Replace(RS("physical_name"), " ", "_") & " " & _
                      RS("MaxSize") & " " & RS("AllocatedSize") & " " & RS("UsedSize")) & _
                      " " & RS("Unlimited")
            RS.MoveNext
        Loop
        RS.Close
    Next

    ' Loop all databases to get the size of the transaction log
    addOutput(sections("datafiles"))
    For Each dbName in dbNames.Keys
        RS.Open "USE [" & dbName & "];", CONN
        RS.Open "SELECT name, physical_name," &_
                "  cast(max_size/128 as bigint) as MaxSize," &_
                "  cast(size/128 as bigint) as AllocatedSize," &_
                "  cast(FILEPROPERTY (name, 'spaceused')/128 as bigint) as UsedSize," &_
                "  case when max_size = '-1' then '1' else '0' end as Unlimited" &_
                " FROM sys.database_files WHERE type_desc = 'ROWS'", CONN
        Do While Not RS.Eof
            addOutput( instance_id & " " & Replace(dbName, " ", "_") & " " & Replace(RS("name"), " ", "_") & _
                      " " & Replace(RS("physical_name"), " ", "_") & " " & _
                      RS("MaxSize") & " " & RS("AllocatedSize") & " " & RS("UsedSize")) & _
                      " " & RS("Unlimited")
            RS.MoveNext
        Loop
        RS.Close
    Next

    ' Database properties, full list at https://msdn.microsoft.com/en-us/library/ms186823.aspx
    addOutput(sections("databases"))
    RS.Open "SELECT name, " & _
            "DATABASEPROPERTYEX(name, 'Status') AS Status, " & _
            "DATABASEPROPERTYEX(name, 'Recovery') AS Recovery, " & _
            "DATABASEPROPERTYEX(name, 'IsAutoClose') AS auto_close, " & _
            "DATABASEPROPERTYEX(name, 'IsAutoShrink') AS auto_shrink " & _
            "FROM master.dbo.sysdatabases", CONN
    Do While Not RS.Eof
        ' instance db_name status recovery auto_close auto_shrink
        addOutput( instance_id & " " & Replace(Trim(RS("name")), " ", "_") & " " & Trim(RS("Status")) & _
                   " " & Trim(RS("Recovery")) & " " & Trim(RS("auto_close")) & " " & Trim(RS("auto_shrink")) )
        RS.MoveNext
    Loop
    RS.Close

    addOutput(sections("clusters"))
    Dim active_node, nodes
    For Each dbName in dbNames.Keys : Do
        RS.Open "USE [" & dbName & "];", CONN
    
        ' Skip non cluster instances
        RS.Open "SELECT SERVERPROPERTY('IsClustered') AS is_clustered", CONN
        If RS("is_clustered") = 0 Then
            RS.Close
            Exit Do
        End If
        RS.Close
        
        nodes = ""
        RS.Open "SELECT nodename FROM sys.dm_os_cluster_nodes", CONN
        Do While Not RS.Eof
            If nodes <> "" Then
                nodes = nodes & ","
            End If    
            nodes = nodes & RS("nodename")
            RS.MoveNext
        Loop
        RS.Close

        active_node = "-"
        RS.Open "SELECT SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS active_node", CONN
        Do While Not RS.Eof
            active_node = RS("active_node")
            RS.MoveNext
        Loop
        RS.Close
        
        addOutput(instance_id & " " & Replace(dbName, " ", "_") & " " & active_node & " " & nodes)
    Loop While False: Next

    CONN.Close

Loop While False: Next

Set sources = nothing
Set instances = nothing
Set sections = nothing
Set RS = nothing
Set CONN = nothing
Set FSO = nothing
Set SHO = nothing
