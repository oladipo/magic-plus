#!/usr/bin/perl

use DBI;
use warnings;

my $driver = "mysql";
my $database = "magic_plus";
my $dsn = "DBI:$driver:database=$database";
my $userid = "root";
my $password = "faraday";
my $dbtable = "ussd";

#$dbh->commit or die $DBI::errstr;

saveUserSession("2348077581487","23413423","*400*1*2*3*1#");


sub saveUserSession(){
	
	my $dbh = DBI->connect($dsn, $userid, $password) or die $DBI::errstr;

	my $query = $dbh->prepare("insert into $dbtable (msisdn, session_id, short_message)
					 values (?,?,?)");

	$query->execute($_[0], $_[1], $_[2]) or die $DBI::errstr;

	$query->finish();
}
