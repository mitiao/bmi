#!/usr/bin/perl -w
use strict;
use 5.010;
use SOAP::Transport::HTTP;
use XMLRPC::Lite;
use DateTime;
use YAML qw/LoadFile/;
use Path::Tiny;
use SVG::TT::Graph::Line;
use Data::Dumper;

our ($username, $password);
eval (`cat $ENV{HOME}/.bmirc`);

my $bugzillahandle;
sub bugzillahandle() {
    $bugzillahandle = XMLRPC::Lite->proxy("https://apibugzilla.novell.com/xmlrpc.cgi") if(!$bugzillahandle);
    return $bugzillahandle;
}

sub SOAP::Transport::HTTP::Client::get_basic_credentials {
    return $username => $password;
}

my $proxy = bugzillahandle();

sub get_product_id_list {
	my $soapresult;
	$soapresult = $proxy->call('Product.get_accessible_products');
	my $product_id_list = $soapresult->{_content}->[4]->{params}->[0]->{ids};
	return $product_id_list;
}

sub get_product_id_name_list {
	my ($product_id_list) = @_;
	my $soapresult;
	foreach (@$product_id_list) {
		$soapresult = $proxy->call('Product.get', {ids => [$_]});
		my $product_name = $soapresult->{_content}->[4]->{params}->[0]->{products}->[0]->{name};
		say $_.' => '.$product_name;
	}
}

sub fetch_bugs {
	my $product_name = shift;
	my $soapresult;
	$soapresult = $proxy->call('Bug.search', {product => [$product_name]});
	return $soapresult->{_content}->[4]->{params}->[0]->{bugs};
}

sub convert_date {
	my ($date, $ym_flag) = @_;
	my @ymd_date;
	if ($date =~ /\d{4}[-|\/]\d{2}[-|\/]\d{2}/) {
		@ymd_date = split /-|\//, $date;
	}
	if ($date =~ /(^\d{4})(\d{2})(\d{2})/) {
		push @ymd_date, $1;
		push @ymd_date, $2;
		push @ymd_date, $3;
	}
	if ($ym_flag) {
		my $dt = DateTime->new(year => $ymd_date[0], month => $ymd_date[1]);
		return $dt;
	} else {
		my $dt = DateTime->new(year => $ymd_date[0], month => $ymd_date[1], day => $ymd_date[2]);
		return $dt;
	}
}

sub get_monthly_period {
	my ($dt_start, $dt_end) = @_;

	my $periods;
	while($dt_start <= $dt_end) {
		my $href = { open => 0,  close => 0 };
		my $key = $1 if $dt_start->ymd('') =~ /(^\d{6})/;
		$periods->{$key} = $href;
		$dt_start->add(months => 1);
	}
	return $periods;
}

sub generate_monthly_data {
	my ($bugs, $periods, $cycle_start, $cycle_end) = @_;
	foreach (@$bugs) {
		my $create_time = $_->{creation_time};
		my $finish_time = $_->{last_change_time};
		my $resolution = $_->{resolution};
		my $status = $_->{status};

		next if ($resolution eq 'INVALID' || $resolution eq 'DUPLICATE');
		next if (!exists $periods->{substr($create_time, 0, 6)});
		next if (convert_date($create_time) < convert_date($cycle_start) || convert_date($create_time) > convert_date($cycle_end));

		$periods->{substr($create_time, 0, 6)}->{open} += 1;
		if ($status eq 'VERIFIED' || $status eq 'RESOLVED') {
			if (convert_date($finish_time) >= convert_date($cycle_start) && convert_date($finish_time) <= convert_date($cycle_end)) {
				$periods->{substr($finish_time, 0, 6)}->{close} += 1;
			}
		}
	}
	return $periods;
}

sub get_milestone_period {
    my $config = shift;
    my $period;

    my $len = scalar @$config;
    for (my $i = 0; $i < $len; $i++) {
        my ($next_start) = values %{$config->[$i+1]};
        $next_start = DateTime->today()->ymd('') if (!defined $next_start);

        my ($key, $start) = each %{$config->[$i]};

        my $href = {milestone => $key, open => 0, close => 0, start => $start, next_start => $next_start};
        $period->{$i} = $href;
    }
    return $period;
}

sub generate_milestone_data {
	my ($bugs, $periods) = @_;
	foreach (@$bugs) {
		my $create_time = $_->{creation_time};
		my $finish_time = $_->{last_change_time};
		my $resolution = $_->{resolution};
		my $status = $_->{status};

		next if ($resolution eq 'INVALID' || $resolution eq 'DUPLICATE');
		foreach (keys %$periods) {
	        my $start = $periods->{$_}->{start};
	        my $next_start = $periods->{$_}->{next_start};
	        if (convert_date($create_time) >= convert_date($start) && convert_date($create_time) < convert_date($next_start)) {
	        	$periods->{$_}->{open} += 1;
	        }
	        if (convert_date($finish_time) >= convert_date($start) && convert_date($finish_time) < convert_date($next_start)) {
	        	$periods->{$_}->{close} += 1;
	        }
	    }
	}
	return $periods;
}

sub caculate_plot_bmi {
	my ($data, $product_name, $interval, $cycle, $cycle_start, $cycle_end) = @_;
	my (@periods, @bmi, @mean);
	my (@open, @close);
	my ($rotate, $sub_title);

	if ($interval eq 'monthly') {
		foreach (sort keys %{$data}) {
			my $xais = $_;
			my $open = $data->{$_}->{open};
			my $close = $data->{$_}->{close};
			if ($open == 0) {
				$sub_title .= "$xais has $open opened and $close closed";
				next;
			} else {
				push @bmi, int($close / $open * 100);
				push @periods, $xais;
			}
			push @open, $open;
			push @close, $close;
		}
		$periods[0] = $cycle_start;
		$periods[-1] = $cycle_end;
		$rotate = 0;
	}
	if ($interval eq 'milestone') {
		foreach (sort {$a <=> $b} keys %{$data}) {
			my $xais = $data->{$_}->{milestone}.'-'.$data->{$_}->{start};
			my $open = $data->{$_}->{open};
			my $close = $data->{$_}->{close};
			if ($open == 0) {
				$sub_title .= "$xais has $open opened and $close closed";
				next;
			} else {
				push @bmi, int($close / $open * 100);
				push @periods, $xais;		
			}
			push @open, $open;
			push @close, $close;
		}
		$rotate = 1;
	}
	@mean = map {$_ = 100} 0..$#periods;

	my $graph = SVG::TT::Graph::Line->new({
		'height'                 => '520',
		'width'                  => '1100',
		'fields'                 => \@periods,
		'show_graph_title'       => 1,		
		'graph_title'            => $product_name.' BMI Graph',
		'show_graph_subtitle'    => 1,
   		'graph_subtitle'         => $interval.' '.$cycle,
		'scale_integers'         => 1,
		'show_x_title'           => 1,
    	'x_title'                => $sub_title,
    	'show_y_title'           => 1,
    	'y_title_text_direction' => 'bt',
    	'y_title'                => 'BMI',
    	# 'rotate_x_labels'        => $rotate,
    	'stagger_x_labels'       => 1,
	});

	$graph->add_data({
		'data'  => \@bmi,
	});

	$graph->add_data({
		'data' => \@mean,
	});

	my $openclose = SVG::TT::Graph::Line->new({
		'height'                 => '520',
		'width'                  => '1100',
		'fields'                 => \@periods,
		'show_graph_title'       => 1,		
		'graph_title'            => $product_name.' Bugs Number Graph',
		'show_graph_subtitle'    => 1,
   		'graph_subtitle'         => $interval.' '.$cycle,
		'scale_integers'         => 1,
		'show_x_title'           => 1,
    	'x_title'                => $interval.' '.$cycle,
    	'show_y_title'           => 1,
    	'y_title_text_direction' => 'bt',
    	'y_title'                => 'Open/Close Number',
    	# 'rotate_x_labels'        => $rotate,
    	'stagger_x_labels'       => 1,
	});

	$openclose->add_data({
		'data'  => \@open,
		'title' => 'opened',
	});

	$openclose->add_data({
		'data' => \@close,
		'title' => 'closed',
	});	

	$product_name =~ s/\s+/_/g;
	$cycle =~ s/\s+/_/g;
	my $svg_name = $product_name.'_'.$interval.'_'.$cycle.'.htm';
	my $f = path($svg_name);
	$f->spew($graph->burn());
	$f->append('<br>'."\n");
	$f->append($openclose->burn());

	system("/usr/bin/firefox $svg_name");
	# print $graph->burn();
}

my $yml_file = 'timeline.yml';
my $config = LoadFile($yml_file);

foreach (keys %$config) {
    my $product_name = $_;
    my $bugs = fetch_bugs($product_name);
    foreach (keys %{$config->{$_}}) {
        my $interval = $_;
        if ($interval eq 'milestone') {
        	say "Generating BMI for $product_name $interval...";
		    my $milestone_array = $config->{$product_name}->{milestone};
		    my $milestone_period = get_milestone_period($milestone_array);
		    my $milestone_data = generate_milestone_data($bugs, $milestone_period);
		    caculate_plot_bmi($milestone_data, $product_name, $interval, '', '', '');
		    # print Dumper $milestone_data;
        }
        if ($interval eq 'monthly') {
            my $monthly_array = $config->{$product_name}->{$interval};
            foreach (@$monthly_array) {
                my ($cycle, $v) = each %{$_};
                my ($start, $end) = split /-/, $v;
                $end = DateTime->today()->ymd('') if $end eq 'today';

                say "Generating BMI for $product_name $interval $cycle...";
                my $monthly_period = get_monthly_period(convert_date($start, 1), convert_date($end, 1));
                my $monthly_data = generate_monthly_data($bugs, $monthly_period, $start, $end);
                caculate_plot_bmi($monthly_data, $product_name, $interval, $cycle, $start, $end);
                # print Dumper $monthly_data;
            }
        }
    }
}


