#! /usr/bin/perl

use strict;
use warnings;

use AppConfig;

=encoding UTF-8
=cut

=head1 NAME

backup.pl

Система бекапа

=head1 AUTHOR

Ivan Bessarabov, ivan@bessarabov.ru

=cut

# Получаю параметры из конфигурационного файла - start
my $config_file = "/etc/backup.conf";
my $config = AppConfig->new();
$config->define(
"debug=s",
"log=s",
"backup_server_name=s",
"backup_server_dir=s",
"filename=s",
"tmp_dir=s",
"keep_local_copy=s",
"days_keep=s",
"keep_first_day_backup=s",
"dir=s@",
"file=s@",
"mysql_host=s", 
"mysql_port=s", 
"mysql_user=s", 
"mysql_password=s",
"pg_user=s",
"pg_dumpall=s" 
);
die("Failed to read config file") if !$config->file($config_file);

our $c_debug = $config->debug;
our $c_log = $config->log;
our $c_backup_server_name = $config->backup_server_name;
our $c_backup_server_dir = $config->backup_server_dir;
our $c_filename = $config->filename;
our $c_tmp_dir = $config->tmp_dir;
our $c_keep_local_copy = $config->keep_local_copy;
our $c_days_keep = $config->days_keep;
our $c_keep_first_day_backup = $config->keep_first_day_backup;
our $c_dir = $config->dir;
our $c_file = $config->get("file");
our $c_mysql_host = $config->mysql_host;
our $c_mysql_port = $config->mysql_port;
our $c_mysql_user = $config->mysql_user;
our $c_mysql_password = $config->mysql_password;
our $c_pg_user = $config->pg_user;
our $c_pg_dumpall = $config->pg_dumpall;

# Удаляю конечные слешы
$c_backup_server_dir =~ s{(.*?)/*$}{$1};

# Получаю параметры из конфигурационного файла - end

# Получаю текущую дату и время
my ($g_d_now, $g_t_now) = dt_now();

# Флаг по которому смотрю были ли ошибки (если ошбики были, то нуно отпрвлять на поту)
my $error;

# Текст сообщения, которое будет отправлятся на почту
my $email;

write_log("= Starting backup $g_d_now $g_t_now =\n");

# Формирую имя файла
my $filename = gen_filename();

create_dir();

backup_mysql();
backup_pg();
backup_dir();
backup_file();

backup_archive();
backup_crypt();
backup_send();

delete_local();
delete_remote();

write_log("\nEND\n\n");

print $email if ($error or $c_debug);

=head1 GENERAL FUNCTIONS
=cut

=head2 write_log

 * Получает: 1) строка для записил в лог
 * Возвращает: -

Процедера получает строку и в зависимости от параметров в конфигурационном файле выводит строку на экрн, и/или записывает в лог файл

=cut
sub write_log {
    my ($message) = @_;
    $email .= $message;

    open (LOGFILE, ">>$c_log") or die $!;
    print LOGFILE $message;
    close LOGFILE;
};

=head2 exec_command

 * Получает: 1) строку с командой для выполнения
 * Возвращает: -

Процедура выполняет комманду, которую получила на входе. В случае указания в конфиге необходимости отображать вывод, выдает данные на экран

=cut
sub exec_command {
    my ($command) = @_;
    write_log(" \$ " . $command . "\n");
    my $result = `$command`;
    $error = 1 if $?;
    write_log($result);
};

=head2 create_dir

 * Получает: -
 * Возвращает: -

Создаю папку, куда буду все складывать для бекапа

=cut
sub create_dir {
    write_log("\n== Creating tmp dir ==\n");
    exec_command("mkdir $c_tmp_dir/backup/ 2>&1");
}

=head2 dt_now

 * Получает: -
 * Возвращает: 1) текущую дату в формате YYYY-MM-DD 2) текущее время в формате HH:MM:SS

=cut
sub dt_now {
    (my $Second, my $Minute, my $Hour, my $DayOfMonth, my $Month, my $Year, my $Weekday, my $DayOfYear, my $IsDST) = localtime(time);
    my $RealYear = $Year + 1900;
    $Month++;
    if ($Month < 10) {$Month = "0" . $Month}
    if ($DayOfMonth < 10) {$DayOfMonth = "0" . $DayOfMonth}
    if ($Hour < 10) {$Hour = "0" . $Hour}
    if ($Minute < 10) {$Minute = "0" . $Minute}
    if ($Second < 10) {$Second = "0" . $Second}

    return ("$RealYear-$Month-$DayOfMonth", "$Hour:$Minute:$Second");
}

=head2 d_keep

 * Получает: -
 * Возвращает: 1) дату начиная с которой нужно оставлять бекапы  YYYY-MM-DD 

=cut
sub d_keep {
    (my $Second, my $Minute, my $Hour, my $DayOfMonth, my $Month, my $Year, my $Weekday, my $DayOfYear, my $IsDST) = localtime(time-($c_days_keep * 86400));
    my $RealYear = $Year + 1900;
    $Month++;
    if ($Month < 10) {$Month = "0" . $Month}
    if ($DayOfMonth < 10) {$DayOfMonth = "0" . $DayOfMonth}
    if ($Hour < 10) {$Hour = "0" . $Hour}
    if ($Minute < 10) {$Minute = "0" . $Minute}
    if ($Second < 10) {$Second = "0" . $Second}

    return "$RealYear-$Month-$DayOfMonth";
}

=head2 gen_filename 

 * Получает: -
 * Возвращает: 1) имя файла архива

=cut
sub gen_filename {
    my $filename = $c_filename . $g_d_now . ".tar";
    return $filename;
}

=head2 backup_mysql 

 * Получает: -
 * Возвращает: -

Подключается к базе mysql и создает файл mysql.dump с дампом

=cut
sub backup_mysql {
    write_log("\n== Dumping mysql ==\n");
    if ($c_mysql_host and $c_mysql_port and $c_mysql_user and $c_mysql_password) {
        exec_command("/usr/bin/mysqldump -u $c_mysql_user --password=$c_mysql_password --host=$c_mysql_host --port=$c_mysql_port -A > $c_tmp_dir/backup/mysql.dump");
    }
    else {
        write_log("Not enougth parameters for mysql dump\n");
    }
}

=head2 backup_pg 

 * Получает: -
 * Возвращает: -

С помощью скрипта pg_dumpall создает файл pg.dump с дампом

=cut
sub backup_pg {
    write_log("\n== Dumping postgresql ==\n");
    if ($c_pg_dumpall) {
        exec_command("pg_dumpall -U $c_pg_user > $c_tmp_dir/backup/pg.dump");
    }
    else {
        write_log("Postgresql backup if switched off in config file\n");
    }
}

=head2 backup_dir

 * Получает: -
 * Возвращает: -

Бекапит папки, указанные в конфиге

=cut
sub backup_dir {
    write_log("\n== Copying dir ==\n");
    exec_command("mkdir $c_tmp_dir/backup/dir 2>&1");
    foreach (@$c_dir) {
        exec_command("cp $_ $c_tmp_dir/backup/dir/ -R --parents 2>&1");
    }
}

=head2 backup_file

 * Получает: -
 * Возвращает: -

Бекапит файлы, указанные в конфиге

=cut
sub backup_file {
    write_log("\n== Copying file ==\n");
    exec_command("mkdir $c_tmp_dir/backup/file 2>&1");

    foreach (@$c_file) {
        exec_command("cp $_ $c_tmp_dir/backup/file/ --parents 2>&1");
    }

}

=head2 backup_archive

 * Получает: -
 * Возвращает: -

Архивирует данные

=cut
sub backup_archive {
    write_log("\n== Archiving ==\n");
    exec_command("cd $c_tmp_dir/backup/; tar zcf $c_tmp_dir/$filename * > /dev/null");
};

=head2 backup_crypt

 * Получает: -
 * Возвращает: -

Шифрует данные

=cut
sub backup_crypt {
    write_log("\n== Crypting file ==\n");
    exec_command("mcrypt -q $c_tmp_dir/$filename");
};

=head2 backup_send

 * Получает: -
 * Возвращает: -

Отправляет зашифрованный файл на сервер в том случае, если указано имя сервера в конфиге

=cut
sub backup_send {
    write_log("\n== Sending file ==\n");
    if ($c_backup_server_name) {
        exec_command("scp $c_tmp_dir/$filename.nc $c_backup_server_name:$c_backup_server_dir");
    }
    else {
        write_log("No server info in config file. Not sending file to remote machine.\n");
        unless ($c_keep_local_copy) {
            write_log("Warning! Not sending backup to the server and not saving local copy. Useless running.\n");
        }
    }
};

=head2 delete_local

 * Получает: -
 * Возвращает: -

Удаляет локальные копии файлов

=cut
sub delete_local {
    write_log("\n== Deleting local tmp files ==\n");
    exec_command("rm $c_tmp_dir/backup/mysql.dump") if ($c_mysql_host and $c_mysql_port and $c_mysql_user and $c_mysql_password);
    exec_command("rm $c_tmp_dir/backup/pg.dump") if ($c_pg_dumpall);
    exec_command("rm $c_tmp_dir/$filename");
    exec_command("rm $c_tmp_dir/$filename.nc") unless ($c_keep_local_copy);
    exec_command("rm -rf $c_tmp_dir/backup/dir");
    exec_command("rm -rf $c_tmp_dir/backup/file");
    exec_command("rmdir $c_tmp_dir/backup/");
}

=head2 delete_remove

 * Получает: -
 * Возвращает: -

Удаляет устаревшие удаленные копии на удаленной машине

=cut
sub delete_remote {
    write_log("\n== Deleting remote old files ==\n");
    if ($c_backup_server_name) {
        # Получаю список файлов на сервере
        my $list = `ssh $c_backup_server_name 'ls $c_backup_server_dir/$c_filename*'`;

        my @files = split ("\n", $list);

        # Дата, начиная с которой буду оставлять файлы
        my $d_keep = d_keep();

        # Тут буду собирать список файлов, которые нужно удалить (разделенные пробелами)
        my $files_to_delete;

        # Прохожусь по всем файлам
        foreach (@files) {

            # Сверяю даты. Если дата бекапа ранее даты с которой оставляю файлы - то файл нужно удалять
            if ($_ lt "$c_backup_server_dir/$c_filename$d_keep.tar.nc") {
                # В том случае, если в конофиге указано не удалять бекап от первого числа - не удаляю его
                if (not($c_keep_first_day_backup and ($_ =~ m{$c_backup_server_dir/$c_filename\d{4}-\d{2}-01.tar.nc}))) {
                    $files_to_delete .= " $_";
                }
            }
        }

        if ($files_to_delete) {
            exec_command("ssh $c_backup_server_name 'rm $files_to_delete'");
        }
    }
    else {
        write_log("Can't delete remote copies, no server info.");
    }
}

