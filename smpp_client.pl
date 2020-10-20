#!/usr/bin/perl
use DBI;
use POSIX;
use XML::Simple;
use Net::SMPP;
use Data::Dumper;
use LWP::UserAgent;
use Log::Log4perl qw(get_logger :levels);
use Log::Log4perl::Layout::PatternLayout;
use warnings;

$trace = 1;
$host = "41.203.65.15";
$port = "2038";
$system_id = "SSEMA";
$password = "SSEMA";

#---Database Access Stuff-------#
my $driver = "mysql";
my $database = "magic_plus";
my $dsn = "DBI:$driver:database=$database";
my $userid = "root";
my $dbpassword = "faraday123*";
my $tblSession = "ussd";
my $tblContent = "content";
my $tblServices = "services";
#---Database Access Stuff-------#

Log::Log4perl->init("logger.conf");
my $logger = get_logger("smpp_client");
$logger->level($DEBUG);

my $chargingURL = "http://41.203.65.65:8888/xml";
my $statusCode = 9999;
my $test = 0;

## connect to database.. database handle will be reused for all db transactions....
my $dbh = DBI->connect($dsn, $userid, $dbpassword) or die $DBI::errstr;
	
#my $smpp = Net::SMPP->new_connect($host, Port=>$port, 
#	system_id => $system_id,
#	password => $password) or die "Could not connect to $host : [$port] : $!";

$logger->debug("Sending Bind Transceiver Request to USSDC : $host, remote port : $port");
 
($smpp, $resp_pdu) = Net::SMPP->new_transceiver($host, port => $port,
	interface_version => 0x34,
	system_id => $system_id,
	system_type => $system_id,
	password => $password,
	async => 1) or die "Could not connect to $host : [$port] : $!";

warn Dumper($smpp, $resp_pdu) if $trace;

$logger->debug(Dumper($smpp, $resp_pdu));

while(1){

	$pdu = $smpp->read_pdu() or die;

	print "Received #$pdu->{seq} $pdu->{cmd} \n";

	print $pdu->explain_status(). "\n";

	$logger->debug("Received #$pdu->{seq} $pdu->{cmd} :". $pdu->explain_status());
	
	$logger->debug(Dumper($pdu));

	if($pdu->{cmd} == 0x80000009){
		print "Bind transceiver response received \n";

		$logger->debug("Bind transceiver response received : ".$pdu->explain_status());
	}

	if($pdu->{cmd} == 0x00000005){
		print "deliver_sm received from $pdu->{source_addr} with message: $pdu->{short_message}
			and ussd_service_op : $pdu->{ussd_service_op} \n";

		#log deliver_sm request...log4perl module
		$logger->info("deliver_sm received from $pdu->{source_addr} with message: $pdu->{short_message}
			and ussd_service_op : $pdu->{ussd_service_op} ");

		$msisdn = $pdu->{source_addr};
		$short_message = $pdu->{short_message};
		$session_id = $pdu->{0x1801};

		## 1. Save session to database...	
		&saveSubscriberSession($msisdn, $session_id, $short_message);

		## 2. Charge MSISDN $pdu->{source_addr}
		## if successful.. update session as billed if not log error ... notify customer about
		## charging error?

		# log charging activity..
		if(&checkBalance($msisdn)){
			
			if (&chargeSubscriber($msisdn)){
				&sendMessageResponse($pdu->{sm_default_msg_id}, $pdu->{seq}, $short_message, $msisdn);
				
			}else{
				$statusMessage = "Error processing your request. 
				Please try again later.";
				
				&sendFailureMessage($pdu->{sm_default_msg_id}, $pdu->{seq}, $session_id, $msisdn, $statusMessage);
			}
		}else{
			$statusMessage = "Error processing your request. 
			Please try again later.";
		
			if($statusCode eq "2" or $statusCode eq "3"){
				$statusMessage = "Error processing your request. 
				You have insufficient funds. ";
			}
		
			&sendFailureMessage($pdu->{sm_default_msg_id}, $pdu->{seq}, $session_id, $msisdn, $statusMessage);
		}
	}
}

#&updateSubscriberSession($msisdn, $session_id, $billed, $transRef);

sub updateSubscriberSession(){
	$logger->info("updating session for subscriber $_[0] with session_id $_[1]");
	
	my $query = $dbh->prepare("update $tblSession set timecompleted = ?, billed = ? , transref = ? where session_id = ? and msisdn = ?");

	$query->execute(strftime("%Y-%m-%d %H:%M:%S",localtime(time)), $_[2], $_[3], $_[1], $_[0]) or die $DBI::errstr;
	
	$query->finish();
}
sub saveSubscriberSession(){
	
	#log save subscriber session
	$logger->info("saving session for subscriber $_[0] with session_id $_[1] : $_[2]");

	my $query = $dbh->prepare("insert into $tblSession (msisdn, session_id, short_message)
					 values (?,?,?)");

	$query->execute($_[0], $_[1], $_[2]) or die $DBI::errstr;

	$query->finish();
}
sub generateTransactionId(){
	$transId = int(rand(10000000));
	#my(undef,undef,undef,$mday,$mon,$year,undef,undef,undef) = localtime();
	
	### list slicing ####
	my($mday,$mon,$year) = (localtime())[3, 4, 5];
	
	$year += 1900;
	$mon += 1;
	
	$ref = sprintf("ssema-%04s%02s%02s-$transId", $year, $mon, $mday);

	$logger->debug("Transaction Reference $ref generated for new transaction for $_[0]");
	
	return $ref;
}
sub checkBalance(){
	$logger->debug("Sending get balance request to Charging Gateway : $chargingURL");
	$transRef = &generateTransactionId($_[0]);
	
	my $xmlRequest = '<?xml version="1.0" encoding="UTF-8"?><ChargeRequest xmlns="UCAPNS"><TransactionHeader><TransactionID>'.$transRef.'</TransactionID><Retry>0</Retry></TransactionHeader><OperationCode>32</OperationCode><Rated>1</Rated><MerchantName>SSEMA</MerchantName><Commodity><ID>3</ID><SubID></SubID><Description>MAGIC_PLUS</Description></Commodity><Volume><Amount><Sign>0</Sign><Value>2</Value><Exponent>0</Exponent></Amount><Unit>10000</Unit></Volume><TimeOfEvent><Time>1337209200</Time><TimeOffset>2</TimeOffset></TimeOfEvent><TrafficID>2</TrafficID><ValidityInterval>24</ValidityInterval><AParty><MSISDN>'.$_[0].'</MSISDN><IMSI /><MSC /></AParty><URL /><Domain /><ContentID /></ChargeRequest>';
	
	my $req = HTTP::Request->new('POST', $chargingURL);
	$req->header('Content-Type' => 'application/xml', 'Authorization' => 'Basic c3NlbWE6c3NlbWE=');
	$req->content($xmlRequest);

	my $lwp = LWP::UserAgent->new;
	$resp = $lwp->request($req);
	
	$logger->debug("Receiving response from Charging Gateway : $chargingURL");
	
	$logger->debug(Dumper($resp));
	
	my $xmlResponse = $resp->content;
	
	$logger->debug($xmlResponse);
	my $balance = 0;
	
	#if check balance request is successful
	if($xmlResponse =~ /<ucap:ResponseCode>0<\/ucap:ResponseCode>/){
		#match amount code with regular expression...
		if($xmlResponse =~ /<ucap:AmountValue>(\d+)<\/ucap:AmountValue>/){
			
			$balance = $1/100;
			
			$logger->info("Subscriber $_[0] balance is : $balance.");
			
		}
	}
	
	if($xmlResponse =~ /<ucap:ResponseCode>99<\/ucap:ResponseCode>/){
			
		$balance = 10000;
		
		$logger->info("Subscriber is a post paid account ");
	}
	
	&updateSubscriberSession($msisdn, $session_id, "N", $transRef);
	$price = &getContentPrice($short_message, $msisdn);
	
	return 1 if $balance >= $price;
	
	return 0;
}
sub chargeSubscriber(){
	$logger->debug("Sending charge request to Charging Gateway : $chargingURL");
	$subID = getContentRateCode($short_message, $msisdn);
	$transRef = &generateTransactionId($_[0]);
	#my $json = '{"clientGivenId":"'.$transRef.'", "interfaceName": "com.mcentric.gateway.in.INCreditDebitServices", "methodName":"debitMainAccountByContentCode", "args":['.$_[0].', 41008],"argsClassNames":["java.lang.String","java.lang.String"]}';
	
	my $xmlRequest = '<?xml version="1.0" encoding="UTF-8"?><ChargeRequest xmlns="UCAPNS"><TransactionHeader><TransactionID>'.$transRef.'</TransactionID><Retry>0</Retry></TransactionHeader><OperationCode>0</OperationCode><Rated>1</Rated><MerchantName>SSEMA</MerchantName><Commodity><ID>3</ID><SubID>'.$subID.'</SubID><Description>MAGIC_PLUS</Description></Commodity><Volume><Amount><Sign>0</Sign><Value>2</Value><Exponent>0</Exponent></Amount><Unit>10000</Unit></Volume><TimeOfEvent><Time>1337209200</Time><TimeOffset>2</TimeOffset></TimeOfEvent><TrafficID>2</TrafficID><ValidityInterval>24</ValidityInterval><AParty><MSISDN>'.$_[0].'</MSISDN><IMSI /><MSC /></AParty><URL /><Domain /><ContentID /></ChargeRequest>';
	
	my $req = HTTP::Request->new('POST', $chargingURL);
	$req->header('Content-Type' => 'application/xml', 'Authorization' => 'Basic c3NlbWE6c3NlbWE=');
	$req->content($xmlRequest);

	my $lwp = LWP::UserAgent->new;
	$resp = $lwp->request($req);
	
	$logger->debug("Receiving response from Charging Gateway : $chargingURL");
	
	$logger->debug(Dumper($resp));
	
	my $xmlResponse = $resp->content;
	
	$logger->debug($xmlResponse);
	
	my $billed = 'N';
	
	#match error code with regular expression...
	#---success..
	if($xmlResponse =~ /<ucap:ResponseCode>(\d+)<\/ucap:ResponseCode>/){
		
		$statusCode = $1;
		
		if($statusCode eq "0"){
			$billed = 'Y';
		}
		
		$logger->info("Subscriber $_[0] : Billed Successfully.");
	}
	
	#---failed..
	if($xmlResponse =~ /<ucap:ErrorCode>(\d+)<\/ucap:ErrorCode>/){
		
		$errorCode = $1;
		$logger->info("Error Billing Subscriber $_[0] : Error Code $errorCode");
	}
	
	&updateSubscriberSession($msisdn, $session_id, $billed, $transRef);
	
	return 1 if $test;
	
	return 1 if($billed eq 'Y');
	
	return 0;
}
sub getContentPrice(){
	#get price for content
	$logger->debug("retrieving price for $_[0] for subscriber $_[1]");
	
	my $query = $dbh->prepare("SELECT price FROM $tblServices WHERE UssdCode = ?") or die "Can't prepare statement: $DBI::errstr";
	
	$query->execute($_[0]) or die $DBI::errstr;

	my @row;
	while (@row = $query->fetchrow_array()) {  # retrieve one row
		$price = $row[0];
		$logger->debug(join(", ", @row),);
	}
	
	$logger->debug("price :$price retrieved for $_[0]");
	
	return $price;
}
## Transactional SMPP usage as per Globacom Traffic Control Gateway..
## Openmind API Document...
sub sendMessageResponse(){

	$logger->debug("retrieving content for short code [$_[2]] for msisdn $_[3]");
	$content = &getContent($_[2], $_[3]);
	
	if(!defined($content)){
		$content = "Your request is processing. We will send you a response shortly.";
	}
	$logger->info("Sending deliver_sm_resp response to USSD Gateway | message_id: $_[0] seq num: $_[1]");
	
	$resp = $smpp->deliver_sm_resp(message_payload => $content,
								message_id => $_[0],
								seq => $_[1],
								0x1801 => $pdu->{0x1801},
								0x1802 => $pdu->{data_coding}) or die "Error sending deliver_sm_resp message"; #. $resp->explain_status() if $resp->status();
	
	#log message sending
	
	#log success or failure..
}
sub getContent(){
	#get content for menus...
	$logger->info("retrieving content menu $_[0] for subscriber $_[1]");
	
	my $query = $dbh->prepare("SELECT * FROM $tblContent WHERE serviceId = (SELECT id FROM $tblServices WHERE UssdCode = '$_[0]') ORDER BY dateAdded DESC LIMIT 1") or die "Can't prepare statement: $DBI::errstr";
	
	$query->execute() or die $DBI::errstr;

	my @row;
	my $content;
	
	while (@row = $query->fetchrow_array()) {  # retrieve one row
		$content = $row[2];
		$logger->debug(join(", ", @row),);
	}
	
	return $content;
}
sub getContentRateCode(){
	#get rate code for ussdcode
	$logger->debug("retrieving rate code for $_[0] for subscriber $_[1]");
	
	my $query = $dbh->prepare("SELECT priceCode FROM $tblServices WHERE UssdCode = ?") or die "Can't prepare statement: $DBI::errstr";
	
	$query->execute($_[0]) or die $DBI::errstr;

	my @row;
	while (@row = $query->fetchrow_array()) {  # retrieve one row
		$rateCode = $row[0];
		$logger->debug(join(", ", @row),);
	}
	
	$logger->debug("Rate code :$rateCode retrieved for $_[0]");
	
	return $rateCode;
}
sub sendFailureMessage(){

	$logger->debug("sending billing error message to for msisdn $_[3] for session_id : $_[2]");
	
	$logger->info("Sending deliver_sm_resp response to USSD Gateway | message_id: $_[0] seq num: $_[1]");
	
	$resp = $smpp->deliver_sm_resp(message_payload => $_[4],
								message_id => $_[0],
								seq => $_[1],
								0x1801 => $pdu->{0x1801},
								0x1802 => $pdu->{data_coding}) or die "Error sending deliver_sm_resp message"; 
}
