#/usr/bin/perl -w

#no warnings "experimental::smartmatch";
use feature ':5.10';
use experimental qw( switch );

$file_types = "../types";
$file_common = "common";
$file_devices = "devices";
$file_credentials = "credentials";

$dir_conf = "conf";
$dir_text = "txt";

$credentials_set = 0;
$username = "admin";
$password = "admin";

$timezone = "";

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
    # Time zone settings
    #

    if ($timezone ne "") {
	$config_str .= "time-zone tz ";
	$config_str .= $timezone;
	$config_str .= " 0\n";
	$config_str .= "!\n";    
    }

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
    $config_str .= "ntp client enable\n";
    $config_str .= "ip exf\n";

    #
    # And return complete config
    #

    return $config_str;
}

sub do_tplink_switch {
    my ($hostname, $devindex, $host_type) = @_;
    my ($config_str);

    $config_str = "!Config tp-link switch $hostname\n";

    # $config_str .= "hostname $hostname\n";
    # $config_str .= "ddm enable\n";
    # $config_str .= "!\n";

    #
    # Vlan "database"
    #

    my @numvlans = sort {$a <=> $b} keys %vlan_name;

    # Necessary ??
    # $config_str .= "vlan " . join(",", @numvlans) . "\n";
    # $config_str .= "!\n";

    for my $vlan (@numvlans) {
	$config_str .= "vlan $vlan\n name \"$vlan_name{$vlan}\"\n";
	$config_str .= "!\n";
    }

    $config_str .= "\nip management-vlan $mainvlanid\n\n";

    #
    # AAA stuff
    #

    $config_str .= "user name $username privilege admin password 0 $password\n"; 
    $config_str .= "!\n";

    #
    # Interfaces
    #

    $config_str .= "interface Null0\n";
    $config_str .= "!\n";

    for my $ptype ("fa", "gi") {
	for my $ifno (1..$host_int{$ptype}) {
	    $confptype = $ptype eq "gi" ? "gigabitEthernet 1/0/" : "XXX";
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
    $config_str .= "ntp client enable\n";
    $config_str .= "ip exf\n";

    #
    # And return complete config
    #

    return $config_str;
}

sub do_cisco_switch {
    my ($hostname, $devindex, $host_type) = @_;
    my ($catalyst, $extended, $layer3, $simple, $poe, $linksys);
    my ($cbs, $fifty);

    # Various differences between Cisco switches
    # They are not all the same....
    $layer3 = $host_ostype =~ /^layer3/;
    $simple = $host_ostype =~ /simple/;
    $linksys = $host_ostype =~ /linksys/;
    $poe = $host_ostype =~ /poe/;
    $extended = $host_ostype =~ /3x/;
    $catalyst = $host_ostype =~ /cat$/;
    $cbs = $host_ostype =~ /cbs$/;
    $fifty = $host_ostype =~ /fifty$/;
    # print "hostname $hostname, cbs $cbs\n";


    my $template = $orig_template;

    #
    # Create vlan database command
    # Cisco specific, but perhaps?
    #
    # Set names here for simple switches
    #
    unless($catalyst) {
	$vlandb = "vlan database\nvlan " .
		join(',', sort{ $a <=> $b } keys %vlan_name) . "\n";
	if ($simple) {
	    for my $vlan (sort {$a <=> $b} keys %vlan_name) {
		$vlandb .= "vlan name $vlan $vlan_name{$vlan}\n";
	    }
	}
	$vlandb .= "exit\n";
    } else {
    	# old style Cisco catalyst
	$vlandb = "";
	for my $vlan (sort {$a <=> $b} keys %vlan_name) {
	    $vlandb .= "vlan $vlan\nname $vlan_name{$vlan}\n";
	}
    }
    if ($cbs) {
	$vlandb .= "no ip routing\n";
    }
    $vlandb .= "voice vlan state disabled\n";
    $template =~ s/VLANDB\n/$vlandb/;

    #
    # Definition of vlans for non-simple
    # Name, and for administrative vlan the ip address
    #

    my $vlandefs = "";
    unless ($simple || $catalyst) {
	for my $vlan (sort {$a <=> $b} keys %vlan_name) {
	    $vlandefs .= "interface vlan $vlan\nname $vlan_name{$vlan}\n";
	    if ($vlan == $mainvlanid) {
		$vlandefs .= "no ip address dhcp\nip address $host_network.$host_ip 255.255.255.0\n";
	    }
	    $vlandefs .= "exit\n";
	}
	$vlandefs .= "macro auto disabled\n";
	$vlandefs .= "ip default-gateway $host_network.1\n";
    }
    if ($catalyst) {
	$vlandefs .= "interface vlan $mainvlanid\nno ip address dhcp\nip address $host_network.$host_ip 255.255.255.0\nexit\n";
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
	if ($catalyst) {
	    $stp_cmd = "spanning-tree mode pvst\n";
	} else {
	    if ($spanningtreemode eq "smart") {
		$stp_cmd = "spanning-tree priority $stp_prio\n";
	    } else {
		$stp_cmd = "spanning-tree priority 32768\n";
	    }
	}
    } else {
	$stp_cmd = "no spanning-tree\n";
    }
    $template =~ s/STP_PRIO\n/$stp_cmd/;

    $cf = $simple ? "configure\n" : "";
    $template =~ s/CONFIGURE\n/$cf/;

    $intprefix{"fa"} = $extended ? "1/" : $catalyst ? "0/" : "";
    $intprefix{"gi"} = $extended ? "1/" : $catalyst ? "0/" : "";

    $ifdefs = "";
    for my $ptype ("fa", "gi") {
	for my $ifno (1..$host_int{$ptype}) {
	    $confptype = $ptype;
	    $confprefix = $intprefix{$ptype};
	    $confptype =~ s/(.)./$1/ if $simple;
	    $port = $ptype . $ifno;
	    $ifdefs .= "interface $confptype$confprefix$ifno\n";
	    if (!$port_used{$port}) {
		#
		# Port not defined, shutdown and warn
		#
		$ifdefs .= "shutdown\n";
		print "Warning: interface $port not active!\n";
	    } else {
		my $portmode = "";

		#
		# Old catalyst switch does not like the add
		#  with the first allowed
		# SMB switches require it though
		#
		my $addcmd = $catalyst ? "" : "add";

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
			$ifdefs .= "switchport mode access\n" if ($portmode eq "");
			$portmode = "a";
			$ifdefs .= "switchport access vlan $vlan\n";
		    } elsif ($pv eq "t") {
			# $ifdefs .= "switchport trunk encapsulation dot1q\n" if ($catalyst && $portmode eq "");
			$ifdefs .= "switchport mode trunk\n" if ($portmode eq "");
			$portmode = "t";
			$ifdefs .= "switchport trunk allowed vlan $addcmd $vlan\n";
			$addcmd = "add";
		    } elsif ($pv eq "u") {
			# $ifdefs .= "switchport trunk encapsulation dot1q\n" if ($catalyst && $portmode eq "");
			$ifdefs .= "switchport mode trunk\n" if ($portmode eq "");
			$portmode = "t";
			$ifdefs .= "switchport trunk allowed vlan $addcmd $vlan\n";
			$addcmd = "add";
			my $sepchar = $simple ? "-" : " ";
			$ifdefs .= "switchport trunk native${sepchar}vlan $vlan\n";
		    }
		}
	    }
	    if($stormcontrolmode eq "on") {
		if ($simple || $catalyst || $cbs || $fifty) {
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

    $voice = $simple || $catalyst ? "" : $orig_voice;
    $template =~ s/VOICE\n/$voice/;

    $hostcmd = "hostname $hostname";
    $hostcmd = "set $hostcmd" if ($simple);
    $template =~ s/HOSTNAME\n/$hostcmd\n/;

    #
    # privilege used to be "level"
    # For older catalyst switches password MUST be last option!
    #

    $urest = $simple ? "override-complexity-check" : "privilege 15";
    $confusername = "username $username $urest password $password\n"; 
    $template =~ s/USERNAME\n/$confusername/;

    $sshserver = $layer3  && !$catalyst ? "ip ssh server\nip ssh password-auth\nip telnet server\n" : "";
    $template =~ s/SSHSERVER\n/$sshserver/;

    if ($simple) {
	$snmp = $layer2_snmp;
    } else {
	if ($catalyst) {
	    $snmp = $catalyst_snmp;
	} else {
	    $snmp = $layer3_snmp;
	}
    }

    if ($poe) {
	$poelimit = "power inline limit-mode port\n";
    } else {
	$poelimit = "";
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

    $sntp = "";
    unless ($simple || $linksys || $catalyst) {
	if ($timezone ne "") {
	    $sntp .= 'clock timezone " " '; # setting
	    $sntp .= $timezone;		# time
	    $sntp .= "\n";			# zone
	}
	$sntp .= "clock source sntp\n";
	$sntp .= "sntp unicast client enable\n";
	$sntp .= "sntp unicast client poll\n";
	$sntp .= "sntp server $host_network.1 poll\n";
    }
    if ($catalyst) {
	$sntp .= "ntp peer $host_network.1\n";
    }

    $vtydefs = "";
    if ($catalyst) {
	$vtydefs = "line con 0\nline vty 0 15\nlogin local\n";
    }

    $template =~ s/SNMP\n/$snmp/;
    $template =~ s/SNTP\n/$sntp/;
    $template =~ s/POE\n/$poelimit/;
    $template =~ s/BANNER\n/$banner/;
    $template =~ s/EXIT\n/$ex/;
    $template =~ s/NETWORK\n/$netwdefs/;
    $template =~ s/VTY\n/$vtydefs/;

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
    $outfile = "$dir_text/$hostname.txt";
    open(OUTFILE, ">", "$outfile") || die "Cannot create $outfile";
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

    # print "devindex=$devindex, network=$host_network, fa=", $host_int{"fa"}, ",gi=", $host_int{"gi"} , "\n";

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
	    /(fa|gi)([0-9]+)(\-([0-9]*))?/ || die "$_ not correct portname";
	    $type = $1; $low = $2; 
	    if (defined($3)) {
		$high = $4 ne "" ? $4 : $host_int{$type};
	    } else {
		$high = $low;
	    }
	    # print "high is now $high\n";
	    # $high = defined($4) ? $4 : $low;
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

    my $stmode = $spanningtreemode;
    if ($host_flags =~ /stp:off/) {
	$spanningtreemode = "off";
    }

    if ($dm eq "cisco") {
	$resulting_conf = do_cisco_switch($hostname, $devindex, $dt);
    } elsif ($dm eq "fs") {
	$resulting_conf = do_fs_switch($hostname, $devindex, $dt);
    } elsif ($dm eq "tp-link") {
	$resulting_conf = do_tplink_switch($hostname, $devindex, $dt);
    }

    $spanningtreemode = $stmode;

    if ($ferrors) {
	unlink($outfile);
    } else {
	print OUTFILE $resulting_conf;
    }

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

$catalyst_snmp = <<ENDCATSNMP ;
snmp-server location "WBF Championship"
snmp-server contact "Hans van Staveren <sater\@xs4all.nl>"
snmp-server community public ro
ip http server
ENDCATSNMP

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
SNTP
POE
BANNER
EXIT
NETWORK
VTY
ENDTEMPLATE

open(TYPES, "<:crlf", $file_types) || die "Cannot open \"$file_types\"";
while(<TYPES>) {
    chomp;
    s/\s*#.*//;
    next if /^$/;
    my ($keyw, @rest) = split;
    if ($keyw eq "type") {
	die "wrong number of words @rest" unless ($#rest==4);
	my ($manuf, $type, $fa_ports, $gi_ports, $ostype) = @rest;
	my $devindex = "$manuf:$type";
	# print "$devindex has $fa_ports 100 and $gi_ports 1000, os $ostype\n";
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
    die "$keyw not recognized";
}
close TYPES;

open(COMMON, "<:crlf", $file_common) || die "Cannot open \"$file_common\"";
while(<COMMON>) {
    chomp;
    s/\s*#.*//;
    next if /^$/;
    my ($keyw, @rest) = split;
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
    if ($keyw eq "timezone") {
	$timezone = $rest[0];
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
my (%name_use);
my (%addr_use);
while(<DEVFILE>) {

    chomp;
    s/\s*#.*//;
    next if /^$/;

    my ($name, $addr, $manuf, $type, $ifile, $flags) = split;
    # print "$name has ip-addr $addr and is a $manuf $type switch, conf on $ifile, flags $flags\n";
    if ($name_use{$name}) {
	die "Illegal re-use of $name";
    }
    $name_use{$name} = 1;
    my $network, $netname, $netaddr;
    if ($addr =~ /^((.*):)(.*)$/) {
	$netname = $2;
	$netaddr = $3;
    } else {
	$netname = "";
	$netaddr = $addr;
    }
    die "Unknown network \"$netname\"" unless (defined($networks{$netname}));

    die "Wrong address $netaddr for $name" unless ($netaddr > 1 && $netaddr < 255);
    my $netid = "$netname:$netaddr";
    my $au = $addr_use{$netid};
    #print "$name has netid $netid, au=$au\n";

    if ($au) {
	die "Illegal re-use of $netid";
    }
    $addr_use{$netid} = 1;

    $dev_netname{$name} = $netname;
    $dev_netaddr{$name} = $netaddr;
    $dev_manuf{$name} = $manuf;
    $dev_type{$name} = $type;
    $dev_conf{$name} = $ifile;
    $dev_flags{$name} = $flags;
}
close DEVFILE;

# print "Device";
my $ndevs=0;
my $nerrs=0;
my $ndeverrors=0;

for my $devname (sort keys %dev_type) {
    $ndevs++;
    my $dm = $dev_manuf{$devname};
    my $dt = $dev_type{$devname};
    # print "About to do device $devname, dm=$dm, dt=$dt\n";
    if(do_switch($devname, $dm, $dt)) {
	if ($ferrors) {
	    $nerrs += $ferrors;
	    $ndeverrors++;
	    print "$devname($dm,$dt):\n";
	    print $host_error{$devname};
	    # delete $host_error{$devname};
	}
	$ferrors = 0;
    }
}

print "Made configuration for $ndevs devices with $ndeverrors wrong totalling $nerrs errors\n";
