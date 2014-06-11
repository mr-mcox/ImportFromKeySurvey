package XlsDataWriter;

use Carp;
use strict;
use YAML;
use Spreadsheet::WriteExcel;
use Spreadsheet::WriteExcel::Utility;
use Excel::Writer::XLSX;

BEGIN {
	our ($VERSION, @ISA);
	$VERSION = 0.02;
}

sub new {
	my $class = shift;
	my $config_input = shift; #If hash ref, uses the hash. Otherwise, it assumes it is a filename
	my $additional_arguments_ref = shift;
	
	my %additional_arguments;
	if( ref $additional_arguments_ref eq 'HASH' ){
		%additional_arguments = %{ $additional_arguments_ref };
	}
	
	my %config_hash;
	if( ref $config_input eq "HASH" ){
		%config_hash = %{ $config_input };
	}else{
		open my $config_file, "< $config_input" or croak "Can't open configuration infile $!";
		my $yaml_stream = do { local $/; <$config_file> };
		%config_hash = %{Load($yaml_stream)};
	}
	
	my $self = { 'config_hash' => \%config_hash };
	bless $self, $class;
}

sub write_data_to_xls {
	my $self = shift;
	my %data_hash = %{ shift @_ };
		
	for my $current_file ( @{ $self->{'config_hash'}->{'files_to_modify'} } ){
		$current_file->{'filename'} || croak "No filename specified";
		
		#Delete old file if it exists
		if( -e $current_file->{'filename'} ){
			unlink $current_file->{'filename'};
		}
		
		my $workbook;
		if( $current_file->{'filename'} =~ /xlsx$/ ){
			$workbook = Excel::Writer::XLSX->new( $current_file->{'filename'} ) or croak "Unable to write excel file $current_file->{'filename'}";
		}else{
			$workbook = Spreadsheet::WriteExcel->new( $current_file->{'filename'} ) or croak "Unable to write excel file $current_file->{'filename'}";
		}
		
		
		for my $current_worksheet_info ( @{ $current_file->{'worksheets_to_modify'} } ){
			$current_worksheet_info->{'worksheet_name'} || croak "No worksheet specified in one worksheet for $current_file->{'filename'}";
			
			my $worksheet = $workbook->add_worksheet( $current_worksheet_info->{'worksheet_name'} );
			
			for my $current_range_info ( @{ $current_worksheet_info->{'ranges_to_modify'} } ){
				#Check that required values are available
				$current_range_info->{'start_cell'} || croak "Start cell missing in one range for $current_worksheet_info->{'worksheet_name'}";
				$current_range_info->{'data_list'} || croak "Data list missing in one range for $current_worksheet_info->{'worksheet_name'}";
				ref $data_hash{ $current_range_info->{'data_list'} } eq 'ARRAY' || croak "Data hash does not contain an array of values for $current_range_info->{'data_list'} on worksheet $current_worksheet_info->{'worksheet_name'}";
				
				my ($start_column, $start_row ) = &xl_cell_to_rowcol( $current_range_info->{'start_cell'} );
				
				my @data_to_print = @{$data_hash{ $current_range_info->{'data_list'} }};
								
				my $transpose_row_column;
				
				if( exists $current_range_info->{'transpose_row_column'} ){
					$transpose_row_column = 1;
				}
				
				for (my $i = 0; $i <= $#data_to_print; $i++ ){
					
					#Use multiple columns if they exist
					my @second_data_array;
					if( ref $data_to_print[ $i ] eq 'ARRAY' ){
						@second_data_array = @{ $data_to_print[ $i ] };
					}else{
						@second_data_array = ( $data_to_print[ $i ] );
					}
					
					for ( my $j; $j <= $#second_data_array; $j++){
						my $current_row;
						my $current_column;

						if( $transpose_row_column ){
							$current_row = $start_row + $j;
							$current_column = $start_column + $i;
							my $data_to_print = $second_data_array[ $j ];
							if( $data_to_print =~ /^=/ ){
								$data_to_print = "\'" . $data_to_print;
							}
							$worksheet->write( $current_column, $current_row, $data_to_print );
						}else{
							$current_row = $start_row + $i;
							$current_column = $start_column + $j;
							if( $current_row >= 0 && $current_column >= 0 ){
								my $data_to_print = $second_data_array[ $j ];
								if( $data_to_print =~ /^=/ ){
									$data_to_print = "\'" . $data_to_print;
								}
								$worksheet->write( $current_column, $current_row, $data_to_print );
							}
						}
					}
					
					
				}
			}
		}
		print "Exported $current_file->{'filename'}\n";
		$workbook->close();
	}	
}

1;