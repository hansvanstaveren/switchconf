#/usr/bin/perl -w

#no warnings "experimental::smartmatch";
use feature ':5.10';

$file_common = "common";
$file_devices = "devices";
$file_credentials = "credentials";

$dir_conf = "conf";
$dir_text = "txt";

$credentials_set = 0;
$username = "admin";
$password = "admin";

$ferrors = 0;

sub prompt {
    my ($promptstr) = @_;

    print "$promptstr: ";
    my $answer = <>;
    $answer =~ s/\s*$//;
    return $answer;
}

sub getset_credentials {
    my ($fname) = @_;

    if (open(CRDFILE, "<:crlf", $fname)) {
	while (<CRDFILE>) {
	    chomp;
	    s/\s*#.*//;
	    next if /^$/;

	    my ($keyw, @rest) = split;

	    if ($keyw eq "credentials") {
		$credentials_set = 1;
		$username = $rest[0];
		$password = $rest[1];
		next;
	    }
	    die "$keyw not recognized in $fname";
	}
	close CRDFILE;
    } else {
	#
	# Get it from the operator
	#
	
	$username = prompt("Username");
	$password = prompt("Password");
	open(CRDFILE, ">:crlf", $fname) || die;
	print CRDFILE "credentials $username $password\n";
	close(CRDFILE);
    }
}

sub file_error {
    my ($host, $if, $error) = @_;

    $host_error{$host} .= "$host($if): $error\n";
    $ferrors++;
    return "";
}

#
# Make config for one switch
#

sub do_fs_switch {
    my ($hostname, $devindex, $host_type) = @_;
    my ($config_str);

    $config_str = "!Config FS switch $hostname\n";

    $config_str .= "service timestamps log date\n";
    $config_str .= "service timestamps debug date\n";
    $config_str .= "!\n";

    $config_str .= "hostname $hostname\n";
    $config_str .= "ddm enable\n";
    $config_str .= "!\n";

    #
    # Spanning tree stuff, add priority later
    #

    if ($spanningtreemode ne "off") {
	$config_str .= "spanning-tree mode rstp\n";
    } else {
	$config_str .= "no spanning-tree\n";
    }
    $config_str .= "!\n";

    #
    # AAA stuff
    #

    $config_str .= "aaa authentication login default local\n";
    $config_str .= "aaa authentication enable default none\n";
    $config_str .= "aaa authorization exec default local\n";
    $config_str .= "!\n";

    $config_str .= "username $username password 0 $password\n"; 
    $config_str .= "!\n";

    # SNMP stuff

    $config_str .= "snmp community public ro\n";

    # LLDP stuff

    $config_str .= "lldp run\n";

    #
    # Vlan "database"
    #

    my @numvlans = sort {$a <=> $b} keys %vlan_name;

    # Necessary ??
    $config_str .= "vlan " . join(",", @numvlans) . "\n";
    $config_str .= "!\n";

    for my $vlan (@numvlans) {
	$config_str .= "vlan $vlan\n name $vlan_name{$vlan}\n";
	$config_str .= "!\n";
    }

    #
    # Interfaces
    #

    $config_str .= "interface Null0\n";
    $config_str .= "!\n";

    for my $ptype ("fa", "gi") {
	for my $ifno (1..$host_int{$ptype}) {
	    $confptype = $ptype eq "gi" ? "GigaEthernet0/" : "XXX";
	    $port = $ptype . $ifno;
	    $config_str .= "interface $confptype$ifno\n";

	    $usage = $port_usage{$port};
	    if ($usage eq "") {
		#
		# Port not defined, shutdown and warn
		#
		$config_str .= " shutdown\n";
		print "Warning: interface $port not active!\n";
	    } elsif ($usage =~ /^a(.*)$/) {
		# Single access port
		$config_str .= " switchport pvid $1\n";
	    } else {
		#trunk
		$config_str .= " switchport mode trunk\n";
		my @alloweds;
		for my $vl (split(/,/, $usage)) {
		    $vl =~ /^(.)(.*)$/;
		    my $let = $1;
		    my $vlan = $2;
		    if ($let eq "u") {
			#Untagged VLAN
			$config_str .= " switchport pvid $vlan\n";
			$config_str .= " switchport trunk vlan-untagged $vlan\n";
		    }
		    # And for untagged and tagged
		    push (@alloweds, $vlan);
		}
		$config_str .= " switchport trunk vlan-allowed " . join(",", @alloweds) . "\n";
	    }
	    if ($stormcontrolmode eq "on") {
		$config_str .= " storm-control broadcast threshold 1000\n";
	    }
	    $config_str .= "!\n";
	}
    }

    #
    # Administrative vlan
    #

    $config_str .= "interface VLAN$mainvlanid\n";
    $config_str .= " ip address $host_network.$host_ip 255.255.255.0\n";
    $config_str .= " no ip directed-broadcast\n";
    $config_str .= "!\n";

    #
    # And rest
    #

    $config_str .= "ip route default $host_network.1\n";
    $config_str .= "ip exf\n";
    $config_str .= "!\n";

    $config_str .= "ipv6 exf\n";
    
    $config_str .= "ip http language english\n";
    $config_str .= "ip http server\n";
    $config_str .= "ip exf\n";

    $config_str .= "ntp server $host_network.1\n";
    $config_str .= "ip exf\n";

    #
    # And return complete config
    #

    return $config_str;
}

sub do_cisco_switch {
    my ($hostname, $devindex, $host_type) = @_;
    my ($layer3, $simple, $linksys);

    # Various differences between Cisco switches
    # They are not all the same....
    $layer3 = $host_ostype =~ /^layer3/;
    $simple = $host_ostype =~ /simple/;
    $linksys = $host_ostype =~ /linksys/;


    my $template = $orig_template;

    #
    # Create vlan database command
    # Cisco specific, but perhaps?
    #
    # Set names here for simple switches
    #
    $vlandb = "vlan database\nvlan " .
		join(',', sort{ $a <=> $b } keys %vlan_name) . "\n";
    if ($simple) {
	for my $vlan (sort {$a <=> $b} keys %vlan_name) {
	    $vlandb .= "vlan name $vlan $vlan_name{$vlan}\n";
	}
    }
    $vlandb .= "exit\n";
    $template =~ s/VLANDB\n/$vlandb/;

    #
    # Definition of vlans for non-simple
    # Name, and for administrative vlan the ip address
    #

    my $vlandefs = "";
    unless ($simple) {
	for my $vlan (sort {$a <=> $b} keys %vlan_name) {
	    $vlandefs .= "interface vlan $vlan\nname $vlan_name{$vlan}\n";
	    if ($vlan == $mainvlanid) {
		$vlandefs .= "no ip address dhcp\nip address $host_network.$host_ip 255.255.255.0\n";
	    }
	    $vlandefs .= "exit\n";
	}
	$vlandefs .= "ip default-gateway $host_network.1\n";
    }
    $template =~ s/VLANDEFS\n/$vlandefs/;

    #
    # Set spanning tree priority of best switch(core presumably) better
    #
    $stp_prio =  $hw_stp_prio{$devindex};
    if ($host_flags =~ /stproot/) {
	$stp_prio = 4096;
    }
    # First line for layer1
    # Second for layer2, after hard learning at Orlando
    $stp_cmd = "";
    if ($spanningtreemode ne "off") {
	if ($spanningtreemode eq "smart") {
	    $stp_cmd = "spanning-tree priority $stp_prio\n";
	} else {
	    $stp_cmd = "spanning-tree priority 32768\n";
	}
    } else {
	$stp_cmd = "no spanning-tree\n";
    }
    $template =~ s/STP_PRIO\n/$stp_cmd/;

    $cf = $simple ? "configure\n" : "";
    $template =~ s/CONFIGURE\n/$cf/;

    $ifdefs = "";
    for my $ptype ("fa", "gi") {
	for my $ifno (1..$host_int{$ptype}) {
	    $confptype = $ptype;
	    $confptype =~ s/(.)./$1/ if $simple;
	    $port = $ptype . $ifno;
	    $ifdefs .= "interface $confptype$ifno\n";
	    if (!$port_used{$port}) {
		#
		# Port not defined, shutdown and warn
		#
		$ifdefs .= "shutdown\n";
		print "Warning: interface $port not active!\n";
	    } else {
		for $vlan (sort keys %vlan_name) {
		    my $pv = $portvlan{"$port:$vlan"};
		    #
		    # Is the port on this vlan?
		    #
		    next if (!defined($pv));
		    #
		    # It is, add definition
		    #
		    if ($pv eq "a") {
			$ifdefs .= "switchport mode access\nswitchport access vlan $vlan\n";
		    } elsif ($pv eq "t") {
			$ifdefs .= "switchport trunk allowed vlan add $vlan\n";
		    } elsif ($pv eq "u") {
			my $sepchar = $simple ? "-" : " ";
			$ifdefs .= "switchport trunk native${sepchar}vlan $vlan\n";
		    }
		}
	    }
	    if($stormcontrolmode eq "on") {
		if ($simple) {
		    $ifdefs .= "storm-control broadcast level 5\n";
		    $ifdefs .= "storm-control multicast level 5\n";
		    $ifdefs .= "storm-control unicast level 5\n";
		} else {
		    $ifdefs .= "storm-control broadcast enable\n";
		    $ifdefs .= "storm-control broadcast level 5\n";
		    $ifdefs .= "storm-control include-multicast unknown-unicast\n";
		}
	    }
	    $ifdefs .= "exit\n";
	}
    }
    $template =~ s/IFDEFS\n/$ifdefs/;

    $voice = $simple ? "" : $orig_voice;
    $template =~ s/VOICE\n/$voice/;

    $hostcmd = "hostname $hostname";
    $hostcmd = "set $hostcmd" if ($simple);
    $template =~ s/HOSTNAME\n/$hostcmd\n/;

    # privilege used to be "level"
    $urest = $simple ? "override-complexity-check" : "privilege 15";
    $confusername = "username $username password $password $urest\n"; 
    $template =~ s/USERNAME\n/$confusername/;

    $sshserver = $layer3 ? "ip ssh server\nip telnet server\n" : "";
    $template =~ s/SSHSERVER\n/$sshserver/;

    if ($simple) {
	$snmp = $layer2_snmp;
    } else {
	$snmp = $layer3_snmp;
    }

    if ($simple || $linksys) {
	$banner = "";
    } else {
	$banner = "banner login #\nWBF Championship switch\nNo idle browsing or worse\n#\n";
    }

    if ($simple) {
	$ex = "exit\n";
	$netwdefs = "network protocol none\nnetwork parms $host_network.$host_ip 255.255.255.0 $host_network.1\nnetwork mgmt_vlan $mainvlanid\n";
    } else {
	$ex = "";
	$netwdefs = "";
    }

    $template =~ s/SNMP\n/$snmp/;
    $template =~ s/BANNER\n/$banner/;
    $template =~ s/EXIT\n/$ex/;
    $template =~ s/NETWORK\n/$netwdefs/;

    # change to DOS format
    $template =~ s/\n/\r\n/g;

    return $template;
}

#
# Common code for all manufacturers
# Read and parse .cnf file, call manufacturer dependent code
# that should return the config in a string, and write the string to .txt file
#
sub do_switch {
    my ($hostname, $dm, $dt) = @_;
    my ($resulting_conf);

    # input in a .cnf, output in a .txt
    my $ifile = $dev_conf{$hostname};
    $fname = "$ifile.cnf";
    open(CNFFILE, "<:crlf", "$dir_conf/$fname") || return file_error($hostname, $ifile, "$fname not found");
    $outfile = "$hostname.txt";
    open(OUTFILE, ">", "$dir_text/$outfile") || die "Cannot create $outfile";
    # No extra CR in output, even on Windows/DOS
    binmode OUTFILE;

    undef %host_int;
    undef %port_used;
    undef %port_usage;
    undef %portvlan;

    my $devindex = "$dm:$dt";
    # set up some data based on name and type
    $host_ip = $dev_netaddr{$hostname};
    $host_network = $networks{$dev_netname{$hostname}};
    $host_flags = $dev_flags{$hostname};
    $host_int{"fa"} = $hw_fa{$devindex};
    $host_int{"gi"} = $hw_gi{$devindex};
    $host_ostype = $hw_os{$devindex};

    #print "devindex=$devindex, network=$host_network, fa=", $host_int{"fa"}, ",gi=", $host_int{"gi"} , "\n";

    #
    # Mark all interfaces as unused
    #
    for my $type ("fa", "gi") {
	for my $intno (1..$host_int{$type}) {
	    $port_used{"$type$intno"} = 0;
	    $port_usage{"$type$intno"} = "";
	}
    }

    while (<CNFFILE>) {
	chomp;
	s/\s*#.*//;
	next if /^$/;

	my ($keyword, @parameters) = split;
	if ($keyword ne "port") {
	    # Maybe other keyword some day
	    file_error($hostname, $ifile, "not recognized keyword $keyword");
	    next;
	}
	my (@portids, @vlanids);
	my $ports = $parameters[0];
	my $vlans = $parameters[1];

	my @portranges = split(/,/, $ports);
	for (@portranges) {
	    my ($type, $low, $high);
	    #
	    # Match fa1 and also fa1-6 (same for gi)
	    #
	    /(fa|gi)([0-9]+)(\-([0-9]+))?/ || die "$_ not correct portname";
	    $type = $1; $low = $2; $high = defined($4) ? $4 : $low;
	    if ($low < 1 || $high > $host_int{$type}) {
		file_error($hostname, $ifile, "$type$low-$high does not exist");
		next;
	    }
	    push(@portids, "$type$_") for ($low..$high);
	}
	#
	# Now @portids contains all port names
	#

	#
	# Now vlan(s)
	# Do alias lookup first
	#
	$repl = $synonym{lc $vlans};
	$vlans = $repl if(defined($repl));

	# Now not on alias anymore
	# Split vlan usage
	# Commaseparated, optional letter a, t or u,
	#   followed by single number or range

	$vlanlist = "";
	@vlanranges = split(/,/, $vlans);
	for (@vlanranges) {
	    my ($let, $low, $high);

	    unless ( /^([atu])?([0-9]+)(\-([0-9]+))?/ ) {
		file_error($hostname, $ifile, "$_ not correct vlan");
		next;
	    }
	    $let = $1; $low = $2; $high = defined($4) ? $4 : $low;
	    if (!defined($let)) {
		# No letter, with single number it is access port
		if ($low != $high) {
		    return file_error($hostname, $ifile, "$_ not valid");
		}
		$let = "a";
	    }
	    
	    for ($low..$high) {
		unless (defined($vlan_name{$_})) {
		    file_error($hostname, $ifile, "vlan $_ does not exist");
		    next;
		}
		push(@vlanids, "$let$_");
		if ($let eq "a") {
		    if ($vlanlist ne "") {
			# Access port, must be only def for port
			file_error($hostname, $ifile, "ports @portids: Access port combined with trunk");
			next;
		    }
		    $vlanlist = "a$_";
		} elsif ($let eq "u") {
		    if ($vlanlist =~ /^[au]/) {
			# Untagged vlan, must be only one
			file_error($hostname, $ifile, "ports @portids: untagged vlan with access or more than one untagged");
			next;
		    }
		    $vlanlist = "u$_,$vlanlist";
		} elsif ($let eq "t") {
		    if ($vlanlist =~ /^a/) {
			# Tagged vlan, must not be combined with access
			file_error($hostname, $ifile, "ports @portids: tagged vlan with access");
			next;
		    }
		    $vlanlist .= ",t$_";
		} else {
		    file_error($hostname, $ifile, "internal error");
		    next;
		}
	    }
	}
	$vlanlist =~ s/,,*/,/g;

	#
	# Port usage:
	#
	# a for access
	# t for trunk
	# u for trunk with untagged vlan
	#
	# Some combinations are allowed, some are not
	#

	for $port (@portids) {
	    die "Port $port already in use" if ($port_usage{$port} ne "");
	    $port_usage{$port} = $vlanlist;
	    $port_used{$port} = 1;
	    my $usage = "";
	    for (@vlanids) {
		/^([atu])([0-9]+)$/ || die "internal error";
		#
		# Later definitions of untagged overwrite earlier tagged
		# That is why t30-35,u32 works
		#
		$portvlan{"$port:$2"} = $1;

		given("$1$usage") {
		    # First for unused so far
		    when (/^.$/) { $usage = $_; }
		    when (/^ut$/)    { $usage = "u"; }
		    when (/^(a.|uu|[ut]a)$/) {
			die "port $port misconfigured";
		    }
		}
	    }
	}
    }

    if ($dm eq "cisco") {
	$resulting_conf = do_cisco_switch($hostname, $devindex, $dt);
    } elsif ($dm eq "fs") {
	$resulting_conf = do_fs_switch($hostname, $devindex, $dt);
    }

    print OUTFILE $resulting_conf;

    close(CNFFILE);
    close(OUTFILE);

    return $resulting_conf eq "" ? 0 : 1;
}

$orig_voice = <<ENDVOICE ;
voice vlan oui-table add 0001e3 Siemens_AG_phone________
voice vlan oui-table add 00036b Cisco_phone_____________
voice vlan oui-table add 00096e Avaya___________________
voice vlan oui-table add 000fe2 H3C_Aolynk______________
voice vlan oui-table add 0060b9 Philips_and_NEC_AG_phone
voice vlan oui-table add 00d01e Pingtel_phone___________
voice vlan oui-table add 00e075 Polycom/Veritel_phone___
voice vlan oui-table add 00e0bb 3Com_phone______________
ENDVOICE

$layer3_snmp = <<END3SNMP ;
snmp-server server
snmp-server location "WBF Championship"
snmp-server contact "Hans van Staveren <sater\@xs4all.nl>"
snmp-server community public ro view Default
ip http secure-server
END3SNMP

$layer2_snmp = <<END2SNMP ;
set location "WBF Championship"
set contact "Hans van Staveren <sater\@xs4all.nl>"
END2SNMP

$orig_template = <<ENDTEMPLATE ;
VLANDB
CONFIGURE
STP_PRIO
IFDEFS
VOICE
VLANDEFS
HOSTNAME
USERNAME
SSHSERVER
SNMP
BANNER
EXIT
NETWORK
ENDTEMPLATE

open(COMMON, "<:crlf", $file_common) || die "Cannot open \"$file_common\"";
while(<COMMON>) {
    chomp;
    s/\s*#.*//;
    next if /^$/;
    my ($keyw, @rest) = split;
    if ($keyw eq "type") {
	my ($manuf, $type, $fa_ports, $gi_ports, $ostype) = @rest;
	my $devindex = "$manuf:$type";
	# print "$devindexme has $fa_ports 100 and $gi_ports 1000, os $ostype\n";
	$hw_fa{$devindex} = $fa_ports;
	$hw_gi{$devindex} = $gi_ports;
	$hw_os{$devindex} = $ostype;
	# Awful spanning tree hack, TODO
	$hw_stp_prio{$devindex} = 8;
	if ($type =~ /^sg([23])/ && $gi_ports >= 12) {
	    $hw_stp_prio{$devindex} -= $1;
	}
	$hw_stp_prio{$devindex} *= 4096;
	next;
    }
    if ($keyw eq "vlanbase") {
	$vlanbase = $rest[0];
	next;
    }
    if ($keyw eq "vlan") {
	$rest[0] += $vlanbase;
	$vlan_name{$rest[0]} = $rest[1];
	$synonym{lc $rest[1]} = "a$rest[0]";
	next;
    }
    if ($keyw eq "network") {
	my $network, $netname, $netaddr;
	$network = $rest[0];
	for my $ne (split(/,/, $network)) {
	    if ($ne =~ /^((.*):)(.*)$/) {
		$netname = $2;
		$netaddr = $3;
	    } else {
		$netname = "";
		$netaddr = $ne;
	    }
	    # print "Add network name \"$netname\" with addr $netaddr\n";
	    $networks{$netname} = $netaddr;
	}
	next;
    }
    if ($keyw eq "adminvlan") {
	$mainvlanid = $rest[0]+$vlanbase;
	next;
    }
    if ($keyw eq "alias") {
	my $astr = "";
	for $part (split/([0-9]+)/, $rest[1]) {
	    if ($part =~ /^[0-9]+$/) {
		$part += $vlanbase;
	    }
	    $astr .= $part;
	}
	$synonym{lc $rest[0]} = $astr;
	next;
    }
    if ($keyw eq "spanningtree") {
	$spanningtreemode = $rest[0];
	next;
    }
    if ($keyw eq "stormcontrol") {
	$stormcontrolmode = $rest[0];
	next;
    }
    if ($keyw eq "credentials") {
	$credentials_set = 1;
	$username = $rest[0];
	$password = $rest[1];
	next;
    }
    die "$keyw not recognized";
}
close COMMON;

getset_credentials($file_credentials) unless $credentials_set;

open(DEVFILE, "<:crlf", $file_devices) || die "Cannot open \"$file_devices\"";
while(<DEVFILE>) {
    chomp;
    s/\s*#.*//;
    next if /^$/;
    my ($name, $addr, $manuf, $type, $ifile, $flags) = split;
    print "$name has ip-addr $addr and is a $manuf $type switch, conf on $ifile, flags $flags\n";
    my $network, $netname, $netaddr;
    if ($addr =~ /^((.*):)(.*)$/) {
	$netname = $2;
	$netaddr = $3;
    } else {
	$netname = "";
	$netaddr = $addr;
    }
    die "Unknown network \"$netname\"" unless (defined($networks{$netname}));
    $dev_netname{$name} = $netname;
    $dev_netaddr{$name} = $netaddr;
    $dev_manuf{$name} = $manuf;
    $dev_type{$name} = $type;
    $dev_conf{$name} = $ifile;
    $dev_flags{$name} = $flags;
}
close DEVFILE;

print "Device";
for my $devname (sort keys %dev_type) {
    my $dm = $dev_manuf{$devname};
    my $dt = $dev_type{$devname};
    # print "About to do device $devname, dm=$dm, dt=$dt\n";
    if(do_switch($devname, $dm, $dt)) {
	# print " $devname($dm,$dt)";
    }
}
print"\n";

if ($ferrors) {
    print "Errors:\n";
    for $h (sort keys %host_error) {
	print $host_error{$h};
    }
}
