

no warnings "experimental::smartmatch";
use feature ':5.10';

#
# Make config for one switch
#
sub onefile {
    my ($hostname) = @_;
    my (%port_used, %portvlan);
    my ($host_ip, $host_type, $host_flags, $layer3, $simple, %host_int);

    # input in a .cnf, output in a .txt
    my $ifile = $dev_conf{$hostname};
    $fname = "$ifile.cnf";
    open(CNFFILE, $fname) || die "Cannot open $fname";
    $outfile = "$hostname.txt";
    open(OUTFILE, ">", $outfile) || die "Cannot create $outfile";
    # No extra CR in output, even on Windows/DOS
    binmode OUTFILE;

    # set up some data based on name and type
    $host_ip = $dev_addr{$hostname};
    $host_type = $dev_type{$hostname};
    $host_flags = $dev_flags{$hostname};
    $host_int{"fa"} = $hw_fa{$host_type};
    $host_int{"gi"} = $hw_gi{$host_type};
    $ostype = $hw_os{$host_type};
    $layer3 = $ostype =~ /^layer3/;
    $simple = $ostype =~ /simple/;

    #
    # Mark all interfaces as unused
    #
    for my $type ("fa", "gi") {
	for my $intno (1..$host_int{$type}) {
	    $port_used{"$type$intno"} = 0;
	}
    }

    while (<CNFFILE>) {
	chomp;
	s/\s*#.*//;
	next if /^$/;

	my ($keyword, @parameters) = split;
	if ($keyword eq "port") {
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
		    die "$type$low-$high does not exist";
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

	    @vlanranges = split(/,/, $vlans);
	    for (@vlanranges) {
		my ($let, $low, $high);

		/([atu])?([0-9]+)(\-([0-9]+))?/ || die "$_ not correct vlan";
		$let = $1; $low = $2; $high = defined($4) ? $4 : $low;
		if (!defined($let)) {
		    if ($low != $high) {
			die "$_ not valid";
		    }
		    $let = "a";
		}

		for ($low..$high) {
		    die "vlan $_ does not exist" unless defined($vlan_name{$_});
		    push(@vlanids, "$let$_");
		}
	    }

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
		die "Port $port already in use" if ($port_used{$port});
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
	} else {
	    die "Not recognized $keyword\n";
	}
    }

    my $template = $orig_template;

    $vlandb = "vlan database\nvlan " .
		join(',', sort{ $a <=> $b } keys %vlan_name) . "\n";
    if ($simple) {
	for my $vlan (sort {$a <=> $b} keys %vlan_name) {
	    $vlandb .= "vlan name $vlan $vlan_name{$vlan}\n";
	}
    }
    $vlandb .= "exit\n";
    $template =~ s/VLANDB\n/$vlandb/;

    my $vlandefs = "";
    unless ($simple) {
	for my $vlan (sort {$a <=> $b} keys %vlan_name) {
	    $vlandefs .= "interface vlan $vlan\nname $vlan_name{$vlan}\n";
	    if ($vlan == $mainvlanid) {
		$vlandefs .= "no ip address dhcp\nip address $network.$host_ip 255.255.255.0\n";
	    }
	    $vlandefs .= "exit\n";
	}
	$vlandefs .= "ip default-gateway $network.1\n";
    }
    $template =~ s/VLANDEFS\n/$vlandefs/;

    #
    # Set spanning tree priority of best switch(core presumably) better
    #
    $stp_prio =  $hw_stp_prio{$host_type};
    if ($host_flags =~ /stproot/) {
	$stp_prio = 4096;
    }
    # First line for layer1
    # Second for layer2, after hard learning at Orlando
    $stp_cmd = "";
    if ($spanningtreemode ne "off") {
	if ($spanningtreemode eq "smart") {
	    $stp_cmd = "spanning-tree priority $stp_prio\n";
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
	$banner = "";
	$ex = "exit\n";
	$netwdefs = "network protocol none\nnetwork parms $network.$host_ip 255.255.255.0 $network.1\nnetwork mgmt_vlan $mainvlanid\n";
    } else {
	$snmp = $layer3_snmp;
	$banner = "banner login #\nWBF Championship switch\nNo idle browsing or worse\n#\n";
	$ex = "";
	$netwdefs = "";
    }

    $template =~ s/SNMP\n/$snmp/;
    $template =~ s/BANNER\n/$banner/;
    $template =~ s/EXIT\n/$ex/;
    $template =~ s/NETWORK\n/$netwdefs/;

    # change to DOS format
    $template =~ s/\n/\r\n/g;

    print OUTFILE $template;

    close(CNFFILE);
    close(OUTFILE);
}; # End of one file

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

open(COMMON, "common") || die;
while(<COMMON>) {
    chomp;
    s/\s*#.*//;
    next if /^$/;
    my ($keyw, @rest) = split;
    if ($keyw eq "type") {
	my ($type, $fa_ports, $gi_ports, $ostype) = @rest;
	# print "$type has $fa_ports 100 and $gi_ports 1000, os $ostype\n";
	$hw_fa{$type} = $fa_ports;
	$hw_gi{$type} = $gi_ports;
	$hw_os{$type} = $ostype;
	$hw_stp_prio{$type} = 8;
	if ($type =~ /^sg([23])/ && $gi_ports >= 12) {
	    $hw_stp_prio{$type} -= $1;
	}
	$hw_stp_prio{$type} *= 4096;
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
	$network = $rest[0];
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
    if ($keyw eq "credentials") {
	$username = $rest[0];
	$password = $rest[1];
	next;
    }
    die "$keyw not recognized";
}
close COMMON;

open(DEVFILE, "devices") || die;
while(<DEVFILE>) {
    chomp;
    s/\s*#.*//;
    next if /^$/;
    my ($name, $addr, $type, $ifile, $flags) = split;
    print "$name has ip-addr $addr and is a $type switch, conf on $ifile, flags $flags\n";
    $dev_addr{$name} = $addr;
    $dev_type{$name} = $type;
    $dev_conf{$name} = $ifile;
    $dev_flags{$name} = $flags;
}
close DEVFILE;

print "Device";
for my $devname (sort keys %dev_type) {
    print " $devname";
    onefile($devname);
}
print"\n";
