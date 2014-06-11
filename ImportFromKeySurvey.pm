package ImportFromKeySurvey;
use Carp;
use strict;

use XML::Simple;
use YAML;
#use SOAP::WSDL::Transport::HTTP;
#use MyInterfaces::FormDesignManagement::FormDesignManagementServicePort;
#use MyInterfaces::FormResultManagement::FormResultManagementServicePort;
#use MyInterfaces::FormSettingsManagement::FormSettingsManagementServicePort;
use XML::Compile::WSDL11;      # use WSDL version 1.1
use XML::Compile::SOAP11;      # use SOAP version 1.1
use XML::Compile::Transport::SOAPHTTP;
use XML::Compile::Schema;
use LWP::Simple;
use URI;
use XlsDataWriter;
use Spreadsheet::ParseExcel;
use DBI;
use DateTime;
use feature "switch";

BEGIN {
	our ($VERSION, @ISA);
	$VERSION = 0.01;
}

sub new {
	my $class = shift;
	my $arg_ref = shift;
	my %args;
	
	if( ref $arg_ref eq 'HASH' ){
		%args = %{ $arg_ref };
	}
	
	my $survey_design_ref = $args{'survey_design_config'};
	my $form_to_use = $args{'form_to_use'} || 403449;
	my $survey_code = $args{'survey_code'} || "TEST";
	my $account_id = $args{'account_id'} || 91498;
	my $output_raw_design_file = $args{'output_raw_design_file'} || "none";
	my $force_design_import = $args{'force_design_import'};
	my $error_log_file = $args{'error_log'} || "error_log.log"; 
	my $numerical_responses_table = $args{'numerical_responses_table'} || "numerical_responses";
	my $working_library_path = $args{'working_library_path'} || '/Users/mcox/Dropbox/MDIS/Survey_Dashboards/Code/Working_Library/';
	my %survey_question;
	my @survey_questions_in_order;
	
	my $additional_responses_lines;
	if( exists $args{'additional_responses_file'} ){
		open $additional_responses_lines, "<$args{'additional_responses_file'}" or croak "Can't open additional responses file $args{'additional_responses_file'}: $!";
	}
	
	open my $error_log, ">> $error_log_file" or croak "Can't open error log file $!";

	if( ref $survey_design_ref eq "HASH" ){
		if( ref $survey_design_ref->{'survey_question'} eq "HASH" ){
			%survey_question = %{ $survey_design_ref->{'survey_question'} };
		}
		if( ref $survey_design_ref->{'survey_questions_in_order'} eq "ARRAY" ){
			@survey_questions_in_order = @{ $survey_design_ref->{'survey_questions_in_order'} };
		}
	}
	my $design_import_required = 1;
	if( %survey_question && @survey_questions_in_order && ! $force_design_import ){
		$design_import_required = 0;
	}
	
	my @wsdls = qw( FormDesignManagementService FormResultManagementService FormSettingsManagementService);
	my %wsdl_connections;
	foreach my $wsdl_name ( @wsdls ){
		my $wsdl = XML::Compile::WSDL11->new( $working_library_path .'/WSDL/' . $wsdl_name . '.wsdl');
		my $uri = URI->new($wsdl->endPoint);
		$uri->userinfo('TPSDNationalSurveys:tfatech');
		my $http = XML::Compile::Transport::SOAPHTTP->new(
			address => $uri->as_string
		);
		my $transport = $http->compileClient();
		$wsdl_connections{$wsdl_name} = {'wsdl' => $wsdl, 'transport' => $transport};
	}

	my $self = {
		'form_to_use' 				=> $form_to_use,
		'account_id'				=> $account_id,
		'survey_question' 			=> \%survey_question,
		'survey_questions_in_order' => \@survey_questions_in_order,
		'design_import_required'	=> $design_import_required,
		'survey_code'				=> $survey_code,
		'question_code_file'		=> $args{'question_code_file'},
		'error_log'					=> $error_log,
		'db_handler'				=> $args{'db_handler'},
		'allow_blank_codes'			=> $args{'allow_blank_codes'},
		'numerical_responses_table' => $numerical_responses_table,
		'questions_to_not_delete'	=> $args{'questions_to_not_delete'},
		'do_not_delete_repsonses'	=> $args{'do_not_delete_repsonses'},
		'additional_responses_lines' => $additional_responses_lines,
		'output_raw_design_file'    => $output_raw_design_file,
		'wsdl_connections'			=> \%wsdl_connections
	};
		
	bless $self, $class;
}

sub import_design {
	my $self = shift;
	
	my %survey_question;
	
	if( ref $self->{'survey_question'} eq 'HASH'){
		%survey_question = %{ $self->{'survey_question'} };
	}
	my $form_to_use = $self->{'form_to_use'};
	my $account_id = $self->{'account_id'};
	
	my @survey_questions_in_order;
	
	carp "Importing design";

	#Retrieve all grid rank patterns;
	my $getRankGridPatterns = $self->{'wsdl_connections'}->{'FormSettingsManagementService'}->{'wsdl'}->compileClient(
		operation =>'getRankGridPatterns',
		sloppy_floats => 1, 
		transport => $self->{'wsdl_connections'}->{'FormSettingsManagementService'}->{'transport'}
	);
	my ( $answer, $trace ) = $getRankGridPatterns->({accountId=>$account_id});
	my $result = $trace->{'http_response'}->{_content};
	unless( ref  XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getRankGridPatternsResponse'}->{'return'} eq 'ARRAY'){
		croak "$trace\ngetRankGridPatterns resulted in unexpected output";
	}
	my @rank_grid_patterns = @{ XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getRankGridPatternsResponse'}->{'return'} };
	my %rank_grid_pattern;
	for my $current_pattern ( @rank_grid_patterns ){
		$rank_grid_pattern{ $current_pattern->{'rankGridId'} } = {'pattern_text' => $self->rank_grid_pattern_text($current_pattern) };
	}
	
	#Retrieve all matrix patterns;
	my $getMatrixPatterns = $self->{'wsdl_connections'}->{'FormSettingsManagementService'}->{'wsdl'}->compileClient(
		operation =>'getMatrixPatterns',
		sloppy_floats => 1, 
		transport => $self->{'wsdl_connections'}->{'FormSettingsManagementService'}->{'transport'}
	);
	my ( $answer, $trace ) = $getMatrixPatterns->({accountId=>$account_id});
	my $result = $trace->{'http_response'}->{_content};
	my @matrix_patterns;
	if( ref  XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getMatrixPatternsResponse'}->{'return'} eq 'ARRAY'){
	    @matrix_patterns = @{ XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getMatrixPatternsResponse'}->{'return'} };
	}elsif( ref  XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getMatrixPatternsResponse'}->{'return'} eq 'HASH' ){
	    @matrix_patterns = ( %{ XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getMatrixPatternsResponse'}->{'return'} } );
	}else{
	    croak "$trace\getMatrixPatternsResponse resulted in unexpected output";
	}
	#my %matrix_pattern;
	#for my $current_pattern ( @matrix_patterns ){
	#	$matrix_pattern{ $current_pattern->{'rankGridId'} } = 'Needs development';
	#}
	
	#Retrieve all questions
	my $getFormTree = $self->{'wsdl_connections'}->{'FormDesignManagementService'}->{'wsdl'}->compileClient(
		operation =>'getFormTree',
		sloppy_floats => 1, 
		transport => $self->{'wsdl_connections'}->{'FormDesignManagementService'}->{'transport'}
	);
	( $answer, $trace ) = $getFormTree->({formId=>$form_to_use});
	$result = $trace->{'http_response'}->{_content};
	
	unless( ref  XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getFormTreeResponse'}->{'return'}->{'questions'} eq 'ARRAY'){
		croak "$trace\ngetFormTree resulted in unexpected output";
	}
	if( $self->{'output_raw_design_file'} ne "none" ){
	    open my $RAWDESIGN, "> ", $self->{'output_raw_design_file'} or croak "Can't open raw design file for writing" . $self->{'output_raw_design_file'} . $!;
	    select $RAWDESIGN;
	    print Dump(XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getFormTreeResponse'});
	    close $RAWDESIGN;
	}
	my @question_list = @{ XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getFormTreeResponse'}->{'return'}->{'questions'} };
	
	#Set up service for getting rank grid pattern
	my $getRankGridPattern = $self->{'wsdl_connections'}->{'FormSettingsManagementService'}->{'wsdl'}->compileClient(
		operation =>'getRankGridPattern',
		sloppy_floats => 1, 
		transport => $self->{'wsdl_connections'}->{'FormSettingsManagementService'}->{'transport'}
	);
	
	#Set up service for getting rank grid pattern
	my $getMatrixPattern = $self->{'wsdl_connections'}->{'FormSettingsManagementService'}->{'wsdl'}->compileClient(
		operation =>'getMatrixPattern',
		sloppy_floats => 1, 
		transport => $self->{'wsdl_connections'}->{'FormSettingsManagementService'}->{'transport'}
	);
	
	for (my $question_i; $question_i <= $#question_list; $question_i++ ){
		my $current_question = $question_list[ $question_i ];
		my $question_id = $current_question->{'questionId'};
		push @survey_questions_in_order, $question_id;
		$survey_question{$question_id}->{'answerRequiredType'} = $current_question->{'answerRequiredType'};
		$survey_question{$question_id}->{'xsi:type'} = $current_question->{'xsi:type'};
		$survey_question{$question_id}->{'analysisCode'} = $current_question->{'analysisCode'};
		my @raw_answers;
		my %answer;
		my $has_sub_questions;

		#Determine answer to use
		given ( $survey_question{$question_id}->{'xsi:type'} ){
			when (['ns2:WSSectionHeaderQuestion','ns2:WSSingleLineQuestion','ns2:WSMultiLineQuestion']) {
				$survey_question{$question_id}->{'look_up_value_or_answerId'} = 'text';
			}
			when (['ns2:WSPickOneOrOtherQuestion','ns2:WSPickOneWithCommentQuestion','ns2:WSDropdownQuestion']){
				if( ref $current_question->{'answers'} eq "ARRAY" ){
					@raw_answers = @{ $current_question->{'answers'} };
				}else{
					@raw_answers = ( $current_question->{'answers'}  );
				}
				for (my $answer_i; $answer_i <= $#raw_answers; $answer_i++){
					my %current_answer = %{$raw_answers[$answer_i]};
					$answer{ $current_answer{'answerId'} }->{'questionId'} = $current_answer{'questionId'};
					$answer{ $current_answer{'answerId'} }->{'title'} = $current_answer{'title'};
					$answer{ $current_answer{'answerId'} }->{'display_value'} = $answer_i + 1;
				}
				$survey_question{$question_id}->{'look_up_value_or_answerId'} = 'text_or_answerId';
				$survey_question{$question_id}->{'answer'} = \%answer;
			}
			when (['ns2:WSCheckAllThatApplyQuestion','ns2:WSListBoxQuestion']) {
				$survey_question{$question_id}->{'answer'}->{ 1 }->{'title'} = "x";
				$survey_question{$question_id}->{'answer'}->{ 1 }->{'display_value'} = 1;
				$survey_question{$question_id}->{'answer'}->{ "text" }->{'display_value'} = 1;
				$survey_question{$question_id}->{'look_up_value_or_answerId'} = "text_or_value";
			}
			when (['ns2:WSRankGridQuestion']) {
				#Pull non-account specific rank grid if necessary
				unless( exists $rank_grid_pattern{ $current_question->{'patternId'} } ){
					( $answer, $trace ) = $getRankGridPattern->({rankGridPatternId=> $current_question->{'patternId'}});
					$result = $trace->{'http_response'}->{_content};
					unless( ref  XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getRankGridPatternResponse'}->{'return'} eq 'ARRAY'){
						croak "$trace\ngetRankGridPattern resulted in unexpected output";
					}
					my %result_hash = %{ XML::Simple->new()->XMLin( $result )->{'S:Body'} };
					if( exists $result_hash{'ns2:getRankGridPatternResponse'}->{'return'} ){
						$rank_grid_pattern{ $current_question->{'patternId'} } = {'pattern_text' => $self->rank_grid_pattern_text( $result_hash{'ns2:getRankGridPatternResponse'}->{'return'} ) };
					}else{
						croak "No patternId for $current_question->{'patternId'}. Curent question is:\n" . Dump( $current_question ) . "\n and manual pull result is \n" . Dump( \%result_hash );
					}
				}
				$survey_question{$question_id}->{'look_up_value_or_answerId'} = 'value';
				$survey_question{$question_id}->{'answer'} = $rank_grid_pattern{ $current_question->{'patternId'} }->{'pattern_text'};
			}
			when (['ns2:WSMatrixQuestion']) {
			    #Needs development
		    }
			default { croak "No method to handle answers for question type $survey_question{$question_id}->{'xsi:type'} for question $question_id\n" . Dump $current_question }
		}

		#Determine sub questions and parent questions
		given( $survey_question{$question_id}->{'xsi:type'} ){
			when (['ns2:WSSectionHeaderQuestion','ns2:WSMultiLineQuestion','ns2:WSPickOneOrOtherQuestion','ns2:WSDropdownQuestion']){
				$survey_question{$question_id}->{'title'} = $current_question->{'text'};
				
				if( exists $current_question->{'other'} ){
					my %sub_question;
					my $answerId = $current_question->{'other'}->{'answerId'};
					$survey_question{$question_id}->{'sub_questions_in_order'} = [$answerId];
					$sub_question{ $answerId }->{'order'} = 0;
					$sub_question{ $answerId }->{'title'} = $current_question->{'other'}->{'title'};
					$survey_question{$question_id}->{'sub_question'} = \%sub_question;
				}
			}
			when (['ns2:WSPickOneWithCommentQuestion']) {
				my %sub_question;
				$survey_question{$question_id}->{'title'} = $current_question->{'text'};
				$survey_question{$question_id}->{'sub_questions_in_order'} = ['comment'];
				$sub_question{'comment'}->{'order'} = 0;
				$sub_question{'comment'}->{'title'} = $current_question->{'comment'}->{'title'};
				$survey_question{$question_id}->{'sub_question'} = \%sub_question;
			}
			when (['ns2:WSRankGridQuestion','ns2:WSSingleLineQuestion','ns2:WSCheckAllThatApplyQuestion','ns2:WSListBoxQuestion']) {
				my %sub_question;
				my @sub_questions_in_order;
				$survey_question{$question_id}->{'title'} = $current_question->{'text'};
				if( ref $current_question->{'answers'} eq "ARRAY" ){
					@raw_answers = @{ $current_question->{'answers'} };
				}else{
					@raw_answers = ( $current_question->{'answers'}  );
				}
				for (my $answer_i; $answer_i <= $#raw_answers; $answer_i++){
					my %current_sub_question = %{$raw_answers[$answer_i]};
					$sub_question{ $current_sub_question{'answerId'} }->{'parentQuestionId'} = $current_sub_question{'questionId'};
					push @sub_questions_in_order, $current_sub_question{'answerId'};

					$sub_question{ $current_sub_question{'answerId'} }->{'order'} = $answer_i;
					if( $current_sub_question{'title'} eq "&nbsp;" ){
						$sub_question{ $current_sub_question{'answerId'} }->{'title'} = undef;
					}else{
						$sub_question{ $current_sub_question{'answerId'} }->{'title'} = $current_sub_question{'title'};
					}
				}
				if( exists $current_question->{'other'} && exists $current_question->{'other'}->{'title'} && $current_question->{'other'}->{'title'} ne "" ){
					$sub_question{ $current_question->{'other'}->{'answerId'} }->{'order'} = $#raw_answers + 1;
					$sub_question{ $current_question->{'other'}->{'answerId'} }->{'title'} = $current_question->{'other'}->{'title'};
					push @sub_questions_in_order, $current_question->{'other'}->{'answerId'};
				}
				$survey_question{$question_id}->{'sub_question'} = \%sub_question;
				$survey_question{$question_id}->{'sub_questions_in_order'} = \@sub_questions_in_order;
			}
			when (['ns2:WSMatrixQuestion']) {
			    #Needs development
		    }
			default { croak "No method to handle sub_questions for question type $survey_question{$question_id}->{'xsi:type'} for question $question_id" }
		}
	}
	
	carp "Importing design complete";
	$self->{'survey_question'} = \%survey_question;
	$self->{'survey_questions_in_order'} = \@survey_questions_in_order;
	$self->{'design_import_required'} = 0;
}

sub rank_grid_pattern_text {
	my $self = shift;
	my $current_pattern = shift;
	
	my $i = 1;
	my %pattern_text;
	my @columns = @{$current_pattern->{'columns'}};
	for (my $i; $i <= $#columns; $i++ ){
		$pattern_text{$i + 1 }->{'title'} = $columns[ $i ];
		$pattern_text{$i + 1 }->{'display_value'} = $i + 1;
	}
	
	return \%pattern_text;
}

sub print_design {
	my $self = shift;
	my $outfile = shift || "./survey_design.yaml";
	
	if( $self->{'design_import_required'} ){
		$self->import_design;
	}
	
	open my $OUT, ">:utf8", $outfile or croak "Can't open outfile: " . $!;
	
	select $OUT;
	my $design_hash = { 'survey_question' => $self->{'survey_question'}, 'survey_questions_in_order' => $self->{'survey_questions_in_order'} };
	print Dump $design_hash;
	select STDOUT;
}

sub get_results {
	my $self = shift;
	my %response_for_respondent;
	my $form_to_use = $self->{'form_to_use'};
	my $number_of_respondents;
	
	if( $self->{'design_import_required'} ){
		$self->import_design;
	}
	
	carp "Downloading results";
	
	my %survey_question = %{$self->{'survey_question'}};
	#Set up WSDL
	my $getRespondents = $self->{'wsdl_connections'}->{'FormResultManagementService'}->{'wsdl'}->compileClient(
		operation =>'getRespondents',
		sloppy_floats => 1, 
		transport => $self->{'wsdl_connections'}->{'FormResultManagementService'}->{'transport'}
	);
	my ( $answer, $trace ) = $getRespondents->({formId=>$form_to_use});
	my $result = $trace->{'http_response'}->{_content};
	unless( ref  XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getRespondentsResponse'}->{'return'} eq 'ARRAY'){
		croak "$trace\ngetRespondents resulted in unexpected output";
	}
	my @respondents = @{ XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getRespondentsResponse'}->{'return'} };
	my @respondent_pids;
	
	my $respondents_retrieved;
	
	#Set up responses WSDL
	my $getResponses = $self->{'wsdl_connections'}->{'FormResultManagementService'}->{'wsdl'}->compileClient(
		operation =>'getResponses',
		sloppy_floats => 1, 
		transport => $self->{'wsdl_connections'}->{'FormResultManagementService'}->{'transport'}
	);
	
	select STDOUT;
	print "\n";
	$|=1;
	$self->current_process_start;
	
	for my $current_respondent ( @respondents ){
	    if( $respondents_retrieved > 0 ){
	        #last;
	    }
		if( ( defined $current_respondent->{'code'} && $current_respondent->{'code'} ne "" ) || $self->{'allow_blank_codes'} ){
			my $current_code;
			if( $self->{'allow_blank_codes'} && ( ! defined $current_respondent->{'code'} ||  $current_respondent->{'code'} eq "" ) ){
				$current_code = $current_respondent->{'respondentId'};
			}else{
				$current_code = $current_respondent->{'code'};
			}
			push @respondent_pids, $current_code;
			
			my ( $answer, $trace ) = $getResponses->({respondentId=>$current_respondent->{'respondentId'} });
			my $result = $trace->{'http_response'}->{_content};
			unless( exists XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getResponsesResponse'}->{'return'}){
			    next;
			}
			unless( ref  XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getResponsesResponse'}->{'return'} eq 'ARRAY'){
				croak "$trace\ngetResponses resulted in unexpected output:\n" . Dump(XML::Simple->new()->XMLin( $result ));
			}
			if( ref XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getResponsesResponse'}->{'return'} eq 'ARRAY' ){
				my @questions = @{ XML::Simple->new()->XMLin( $result )->{'S:Body'}->{'ns2:getResponsesResponse'}->{'return'} };

				for my $current_question ( @questions ){
					my $question_id = $current_question->{'questionId'};

					unless( exists $survey_question{ $question_id } ){
						carp "Respondent $current_respondent->{'code'} has questionId of $question_id which does not exist in design";
						next;
					}

					given( $survey_question{ $question_id }->{'xsi:type'} ){
						when (['ns2:WSSectionHeaderQuestion','ns2:WSMultiLineQuestion','ns2:WSDropdownQuestion']){
							$response_for_respondent{ $current_code }->{ $question_id }->{'main'} = $self->retrieve_values_for_answer( $question_id, $current_question->{'answerResponses'} );
						}
						when (['ns2:WSSingleLineQuestion','ns2:WSRankGridQuestion','ns2:WSCheckAllThatApplyQuestion','ns2:WSListBoxQuestion']){
							my @responses;
							if( ref $current_question->{'answerResponses'} eq 'ARRAY' ){
								@responses = @{ $current_question->{'answerResponses'} };
							}else{
								@responses = ( $current_question->{'answerResponses'} );
							}
							for my $current_response ( @responses ){
								$response_for_respondent{ $current_code }->{ $question_id }->{'sub_question'}->{ $current_response->{'answerId'} } = $self->retrieve_values_for_answer( $question_id, $current_response );
							}
						}
						when([ 'ns2:WSPickOneOrOtherQuestion' ]){
							my $current_response = $current_question->{'answerResponses'};
							if( $current_response->{'xsi:type'} eq "ns2:WSAnswerPickResponse" ){
								$response_for_respondent{ $current_code }->{ $question_id }->{'main'} = $self->retrieve_values_for_answer( $question_id, $current_response );
							}else{
								$response_for_respondent{ $current_code }->{ $question_id }->{'sub_question'}->{ $current_response->{'answerId'} } = $self->retrieve_values_for_answer( $question_id, $current_response );
							}
						}
						when (['ns2:WSPickOneWithCommentQuestion']) {
							if( ref $current_question->{'answerResponses'} eq 'HASH' ){
								$response_for_respondent{ $current_code }->{ $question_id }->{'main'} = $self->retrieve_values_for_answer( $question_id, $current_question->{'answerResponses'} );
							}
							if( ref $current_question->{'answerResponses'} eq 'ARRAY' ){
								for my $current_response ( @{ $current_question->{'answerResponses'} } ){
									if( $current_response->{'xsi:type'} eq "ns2:WSAnswerPickResponse" ){
										$response_for_respondent{ $current_code }->{ $question_id }->{'main'} = $self->retrieve_values_for_answer( $question_id, $current_response );
									}else{
										$response_for_respondent{ $current_code }->{ $question_id }->{'sub_question'}->{'comment'} = $self->retrieve_values_for_answer( $question_id, $current_response );
									}
								}
							}
						}
						when (['ns2:WSMatrixQuestion']) {
            			    #Needs development
            		    }
						default { croak "Response retreival method not specified for $question_id with type $survey_question{ $question_id }->{'xsi:type'}" }
					}
				}
			}else{
				$self->log_error("Getting responses failed for " . $current_respondent->{'respondentId'} . ". Dump of response is:\n" . Dump( XML::Simple->new()->XMLin( $result ) ) );
			}
		}
		print "Retrieving responses: " . $self->progress_bar( ++$respondents_retrieved, $#respondents + 1, 25, "=");
	}
	$|=0;
	carp "Downloading results finished";
	$self->{'respondents'} = \@respondent_pids;
	$self->{'responses'} = \%response_for_respondent;
}

sub retrieve_values_for_answer {
	my $self = shift;
	my $question_id = shift;
	my $answer = shift;
	
	my %survey_question = %{$self->{'survey_question'}};
	my %response;
		
	exists $survey_question{ $question_id } or croak "Respondent has questionId of $question_id which does not exist in design";

	given ( $survey_question{ $question_id }->{'look_up_value_or_answerId'} ){
		when ('text') {
			$response{'display_text'} =  $answer->{'text'}
		}
		when ('value') {
			exists $survey_question{ $question_id }->{'answer'}->{ $answer->{'value'} } or croak "The answer for $question_id should have a value, but looks like this: " . Dump $answer;
			
			$response{'display_value'} = $survey_question{ $question_id }->{'answer'}->{ $answer->{'value'} }->{'display_value'};
			$response{'display_text'} = $survey_question{ $question_id }->{'answer'}->{ $answer->{'value'} }->{'title'};
		}
		when ('answerId') {
			exists $survey_question{ $question_id }->{'answer'}->{ $answer->{'answerId'} } or croak "The answer for $question_id should have an answerId, but looks like this: " . Dump $answer;
			
			$response{'display_value'} = $survey_question{ $question_id }->{'answer'}->{ $answer->{'answerId'} }->{'display_value'};
			$response{'display_text'} = $survey_question{ $question_id }->{'answer'}->{ $answer->{'answerId'} }->{'title'};
		}
		when ('text_or_answerId') {
			if( $answer->{'xsi:type'} eq 'ns2:WSAnswerTextResponse' ){
				$response{'display_text'} = $answer->{'text'};
				$response{'display_value'} = $survey_question{ $question_id }->{'answer'}->{ $answer->{'answerId'} }->{'display_value'};
			}else{
				exists $survey_question{ $question_id }->{'answer'}->{ $answer->{'answerId'} } or croak "The answer for $question_id should have an answerId, but looks like this: " . Dump $answer;
				
				$response{'display_value'} = $survey_question{ $question_id }->{'answer'}->{ $answer->{'answerId'} }->{'display_value'};
				$response{'display_text'} = $survey_question{ $question_id }->{'answer'}->{ $answer->{'answerId'} }->{'title'};
			}
		}
		when ('text_or_value') {
			if( $answer->{'xsi:type'} eq 'ns2:WSAnswerTextResponse' ){
				$response{'display_text'} = $answer->{'text'};
				$response{'display_value'} = $survey_question{ $question_id }->{'answer'}->{ 'text' }->{'display_value'};
			}else{
				exists $survey_question{ $question_id }->{'answer'}->{ $answer->{'value'} } or croak "The answer for $question_id should have an value, but looks like this: " . Dump $answer;
				
				$response{'display_value'} = $survey_question{ $question_id }->{'answer'}->{ $answer->{'value'} }->{'display_value'};
				$response{'display_text'} = $survey_question{ $question_id }->{'answer'}->{ $answer->{'value'} }->{'title'};
			}
		}
		default { croak "Unknown look_up_value_or_answerId for $question_id: $survey_question{ $question_id }->{'look_up_value_or_answerId'}"}
	}
	return \%response;
}

sub raw_data_as_matrix {
	my $self = shift;
	
	unless( exists $self->{'respondents'} && exists $self->{'responses'} ){
		$self->get_results;
	}
	
	unless( exists $self->{'raw_data_as_matrix'} ){
		my @primary_header_row;
		my @secondary_header_row;
		my @raw_data_as_matrix;
		my $next_column;
		
		my %survey_question = %{$self->{'survey_question'}};
		
		push @primary_header_row, "PID";
		$next_column = 1;
		
		#Set column headings
		for my $current_question_id ( @{ $self->{'survey_questions_in_order'} } ){
			exists $survey_question{ $current_question_id } or croak "Question order has question $current_question_id but it's not in the survey design";
			my $current_question = $survey_question{ $current_question_id };
			$primary_header_row[ $next_column ] = $survey_question{ $current_question_id }->{'title'};
			$survey_question{ $current_question_id }->{'output_column_num'} = $next_column;
			$next_column++;
			
			#Set columns for sub_questions
			if( exists $survey_question{ $current_question_id }->{'sub_questions_in_order'} ){
				unless($survey_question{ $current_question_id }->{'xsi:type'} eq 'ns2:WSPickOneWithCommentQuestion' ){
					$next_column--;
				}
				for my $current_sub_question_id ( @{ $survey_question{ $current_question_id }->{'sub_questions_in_order'} } ){
					exists $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id } or croak "Sub question order for question $current_question_id has sub_question $current_sub_question_id but it's not in the survey design";
					
					$secondary_header_row[ $next_column ] = $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'title'};
					$survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'output_column_num'} = $next_column;
					$next_column++;
				}
			}
		}
		
		push @raw_data_as_matrix, \@primary_header_row, \@secondary_header_row;
				
		#Set data for each respondent
		for my $current_respondent ( @{ $self->{'respondents'} } ){
			my @data_row = ($current_respondent);
			my @respondent_questions = keys %{ $self->{'responses'}->{ $current_respondent } };
			for my $current_question_id ( @respondent_questions ){
				my $current_question = $self->{'responses'}->{ $current_respondent }->{ $current_question_id };
				if( exists $current_question->{'main'} ){
					exists $survey_question{ $current_question_id }->{'output_column_num'} or croak "Question $current_question_id has a main response from respondent $current_respondent, but design does not have output column\n" . Dump $current_question;
					$data_row[ $survey_question{ $current_question_id }->{'output_column_num'} ] = $current_question->{'main'}->{'display_text'};
				}
				if( exists $current_question->{'sub_question'} ){
					for my $current_sub_question_id ( keys %{ $current_question->{'sub_question'} } ){
						exists $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'output_column_num'} or croak "Question $current_question_id with sub_question_id $current_sub_question_id has a sub_question response from respondent $current_respondent, but design does not have output column\n" . Dump( $current_question ) . "\nDesign:\n" . Dump $survey_question{ $current_question_id };
						$data_row[ $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'output_column_num'} ] = $current_question->{'sub_question'}->{ $current_sub_question_id }->{'display_text'};
					}
				}
			}
			push @raw_data_as_matrix, \@data_row;
		}
		$self->{'raw_data_as_matrix'} = \@raw_data_as_matrix;
		$self->{'survey_question'} = \%survey_question;
	}
	$self->{'raw_data_as_matrix'};
}

sub export_questions_with_question_id{
	my $self = shift;
	
	my $output_file = shift || "question_output.xls";
	
	if( $self->{'design_import_required'} ){
		$self->import_design;
	}
	
	my @primary_header_row = ("Parent Question");
	my @secondary_header_row = ("Sub Question");
	my @question_id = ("Question Id");
	my @answer_id = ("Answer Id");
	my @question_codes = ("Question Code");
	my @confidential = ("Is confidential");
	my @analysis_code = ("Analysis Code");
	my @data_for_export;
	my $next_column = 1;
	
	my %survey_question = %{$self->{'survey_question'}};
	
	#Set column headings
	for my $current_question_id ( @{ $self->{'survey_questions_in_order'} } ){
		exists $survey_question{ $current_question_id } or croak "Question order has question $current_question_id but it's not in the survey design";
		my $current_question = $survey_question{ $current_question_id };
		$primary_header_row[ $next_column ] = $survey_question{ $current_question_id }->{'title'};
		$question_id[ $next_column ] = $current_question_id;
		if( exists $survey_question{ $current_question_id }->{'question_code'} ){
			$question_codes[ $next_column ] = $survey_question{ $current_question_id }->{'question_code'};
		}
		if( exists $survey_question{ $current_question_id }->{'is_confidential'} ){
			$confidential[ $next_column ] = $survey_question{ $current_question_id }->{'is_confidential'};
		}
		if( exists $survey_question{ $current_question_id }->{'analysisCode'} ){
		    my $cur_analysis_code = $survey_question{ $current_question_id }->{'analysisCode'};
		    if( ref $cur_analysis_code eq 'HASH' ){
		        $analysis_code[ $next_column ] = "";
		    }else{
		        $analysis_code[ $next_column ] = $cur_analysis_code;
		    }
		}
		$next_column++;
		
		#Set columns for sub_questions
		if( exists $survey_question{ $current_question_id }->{'sub_questions_in_order'} ){
			unless($survey_question{ $current_question_id }->{'xsi:type'} eq 'ns2:WSPickOneWithCommentQuestion' ){
				$next_column--;
			}
			$question_id[ $next_column ] = $current_question_id;
			for my $current_sub_question_id ( @{ $survey_question{ $current_question_id }->{'sub_questions_in_order'} } ){
				exists $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id } or croak "Sub question order for question $current_question_id has sub_question $current_sub_question_id but it's not in the survey design";
				
				$secondary_header_row[ $next_column ] = $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'title'};
				$question_id[ $next_column ] = $current_question_id;
				$answer_id[ $next_column ] = $current_sub_question_id;
				if( exists $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'question_code'} ){
					$question_codes[ $next_column ] = $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'question_code'};
				}
				if( exists $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'is_confidential'} ){
					$confidential[ $next_column ] = $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'is_confidential'};
				}
				$next_column++;
			}
		}
	}
	
	push @data_for_export, \@primary_header_row, \@secondary_header_row, \@question_id, \@answer_id, \@question_codes, \@confidential, \@analysis_code;
	
	my %xls_config = (
		'files_to_modify' => [
			{
				'filename' => $output_file,
				'worksheets_to_modify' => [
					{
						'worksheet_name' => "questions",
						'ranges_to_modify' => [
							{
								'start_cell' => "A1",
								'data_list'  => "data_for_export",
							}
						]
					},
				]
			}
		]
	);
	
	my %data_hash = ( 'data_for_export' => \@data_for_export );
	
	my $data_writer = XlsDataWriter->new( \%xls_config );
	$data_writer->write_data_to_xls(\%data_hash);
}

sub export_results_to_database {
	my $self = shift;
	
	$self->{'db_handler'} or croak "db_handler not defined - it is needed for export_results_to_database";
	my $db_handler = $self->{'db_handler'};
	my $questions_to_not_delete_string;
	if( ref $self->{'questions_to_not_delete'} eq 'ARRAY' ){
		$questions_to_not_delete_string = "AND survey_specific_qid NOT IN (\"" . join( "\",\"", @{ $self->{'questions_to_not_delete'} } ) . "\")";
	}
	
	my $old_data_deletion_statement_handler = $db_handler->prepare("DELETE FROM $self->{'numerical_responses_table'} WHERE survey = ? $questions_to_not_delete_string") or croak "Preparing deletion of old survey responses failed: " .  $db_handler->errstr;
	unless($self->{'do_not_delete_repsonses'}){
	    $old_data_deletion_statement_handler->execute( $self->{'survey_code'} )  or croak "Deleting old survey responses failed: " .  $db_handler->errstr;
	}
	my $new_data_insertion_statement_handler = $db_handler->prepare("INSERT INTO $self->{'numerical_responses_table'} (cm_pid, survey, survey_specific_qid, response) VALUES (?, ?, ?, ?)") or croak "Preparing insertion of responses failed: " .  $db_handler->errstr;
	
	unless( exists $self->{'respondents'} && exists $self->{'responses'} ){
		$self->get_results;
	}
	
	if( defined $self->{'additional_responses_lines'} ){
		my $additional_responses_lines = $self->{'additional_responses_lines'};
		while ( <$additional_responses_lines> ){
			chomp;
			my @additional_response_fields = split "\t", $_;
			$new_data_insertion_statement_handler->execute( $additional_response_fields[0], $additional_response_fields[1], $additional_response_fields[2], $additional_response_fields[3] );
		}
	}
	
	carp "Exporting results to database";
	my $total_respondents = $#{ $self->{'respondents'} } + 1;
	my $number_of_respondents_processed;
	$self->current_process_start;
	
	$|=1;
	
	my %survey_question = %{ $self->{'survey_question'} };
	
	#carp Dump( $self->{'responses'} );
	
	for my $current_respondent ( @{ $self->{'respondents'} } ){
		my @respondent_questions = keys %{ $self->{'responses'}->{ $current_respondent } };
		#carp "Respondent $current_respondent has $#respondent_questions to be inserted";
		for my $current_question_id ( @respondent_questions ){
			my $current_question = $self->{'responses'}->{ $current_respondent }->{ $current_question_id };
			if( exists $current_question->{'main'}->{'display_value'} && exists $survey_question{ $current_question_id }->{'question_code'} && defined $current_question->{'main'}->{'display_value'} && $current_question->{'main'}->{'display_value'} ne "" && $survey_question{ $current_question_id }->{'question_code'} ne "" ){
				#carp "Inserting value for " . join("-", $self->{'survey_code'}, $survey_question{ $current_question_id }->{'question_code'} );
				$new_data_insertion_statement_handler->execute(
					$current_respondent,
					$self->{'survey_code'},
					join("-", $self->{'survey_code'}, $survey_question{ $current_question_id }->{'question_code'} ),
					$current_question->{'main'}->{'display_value'}
					) or $self->log_error( "Inserting values failed: " . $db_handler->errstr );				
			}else{
				#carp "Display value is " . $current_question->{'main'}->{'display_value'} . " and code is " . $survey_question{ $current_question_id }->{'question_code'} . " and value is " . $current_question->{'main'}->{'display_value'} . " Full Dump of survey:\n" . Dump($survey_question{ $current_question_id });
			}
			if( exists $current_question->{'sub_question'} ){
				for my $current_sub_question_id ( keys %{ $current_question->{'sub_question'} } ){
					if( exists $current_question->{'sub_question'}->{ $current_sub_question_id }->{'display_value'} && defined $current_question->{'sub_question'}->{ $current_sub_question_id }->{'display_value'} && $current_question->{'sub_question'}->{ $current_sub_question_id }->{'display_value'} ne "" && exists $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'question_code'} && $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'question_code'} ne "" ){
						$new_data_insertion_statement_handler->execute(
							$current_respondent,
							$self->{'survey_code'},
							join("-", $self->{'survey_code'}, $survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id }->{'question_code'} ),
							$current_question->{'sub_question'}->{ $current_sub_question_id }->{'display_value'}
							) or $self->log_error( "Inserting values failed: " . $db_handler->errstr );
					}else{
					    #carp " Full Dump of survey design:\n" . Dump($survey_question{ $current_question_id }->{'sub_question'}->{ $current_sub_question_id } ) . "response\n" . Dump($current_question->{'sub_question'}->{ $current_sub_question_id });
					}
				}
			}
		}
		$number_of_respondents_processed++;
		if( $number_of_respondents_processed % 100 == 0 ){
			print "Importing Results to database: " . $self->progress_bar( $number_of_respondents_processed, $total_respondents + 1, 25, "=");
		}
	}
	$|=0;
	print "\nFinished exporting results to database\n";
}

sub import_question_codes{
	my $self = shift;
	
	if( $self->{'design_import_required'} ){
		$self->import_design;
	}
	
	my %survey_question = %{ $self->{'survey_question'} };
	
	my $excel_parser = new Spreadsheet::ParseExcel;
	
	$self->{'question_code_file'} or croak "Question code isn't defined"; 
	my $excel_file = $excel_parser->Parse( $self->{'question_code_file'} );
	my $data_worksheet = $excel_file->Worksheet("questions");
	my ($min_row, $max_row) = $data_worksheet->RowRange();
	my ($min_column, $max_column) = $data_worksheet->ColRange();
	
	my $start_row = 1;
	my $question_id_column = 2;
	my $sub_question_id_column = 3;
	my $question_code_column = 4;
	my $confidential_column = 5;
	
	for (my $current_row = $max_row; $current_row >= $start_row; $current_row--){
		if( defined $data_worksheet->{Cells}[$current_row][$question_code_column] && defined $data_worksheet->{Cells}[$current_row][$question_code_column]->Value ){
			
			my $question_id;
			if( defined $data_worksheet->{Cells}[$current_row][$question_id_column]){
				$question_id = $data_worksheet->{Cells}[$current_row][$question_id_column]->Value;
			}
			my $sub_question_id;
			if( defined $data_worksheet->{Cells}[$current_row][$sub_question_id_column]){
				$sub_question_id = $data_worksheet->{Cells}[$current_row][$sub_question_id_column]->Value;
			}
			my $question_code;
			if( defined $data_worksheet->{Cells}[$current_row][$question_code_column] ){
				$question_code = $data_worksheet->{Cells}[$current_row][$question_code_column]->Value;
			}
			my $is_confidential;
			if( defined $data_worksheet->{Cells}[$current_row][$confidential_column] ){
				$is_confidential = $data_worksheet->{Cells}[$current_row][$confidential_column]->Value;
			}
			
			if( exists $survey_question{ $question_id } ){
				if( defined $sub_question_id && $survey_question{ $question_id }->{"xsi:type"} ne "ns2:WSPickOneOrOtherQuestion" ){
					if( exists $survey_question{ $question_id }->{'sub_question'}->{ $sub_question_id } ){
						$survey_question{ $question_id }->{'sub_question'}->{ $sub_question_id }->{'question_code'} = $question_code;
						$survey_question{ $question_id }->{'sub_question'}->{ $sub_question_id }->{'is_confidential'} = $is_confidential;
					}
				}else{
					$survey_question{ $question_id }->{'question_code'} = $question_code;
					$survey_question{ $question_id }->{'is_confidential'} = $is_confidential;
				}
			}
		}
	}
}

sub export_raw_results {
	my $self = shift;
	my $output_file = shift || "raw_data_output.xlsx";
	
	my %xls_config = (
		'files_to_modify' => [
			{
				'filename' => $output_file,
				'worksheets_to_modify' => [
					{
						'worksheet_name' => "raw_data",
						'ranges_to_modify' => [
							{
								'start_cell' => "A1",
								'data_list'  => "raw_data_as_matrix",
								'transpose_row_column' => "Y"
							}
						]
					},
				]
			}
		]
	);
	
	my %data_hash = ( 'raw_data_as_matrix' => $self->raw_data_as_matrix );
	
	carp "Exporting raw results to excel file";
	
	my $data_writer = XlsDataWriter->new( \%xls_config );
	$data_writer->write_data_to_xls(\%data_hash);
	
	carp "Finished raw exporting results to excel file";
}

sub log_error {
	my $self = shift;
	my $error_string = shift;
	
	print { $self->{'error_log'} } localtime . " $error_string\n";
}

sub current_process_start {
	my $self = shift;
	$self->{'current_process_start_time'} = DateTime->now;
}

sub expected_finish_string {
	my $self = shift;
	my $percent_complete = shift;
	
	unless( $percent_complete ){ return "No percent complete given to estimate time"}
	
	my $current_time = DateTime->now;
	my $start_time = $self->{'current_process_start_time'} || return {"No start time set"};
	my $elapsed_time = $current_time - $start_time;
	my $elapsed_seconds = $elapsed_time->seconds + 60*($elapsed_time->minutes + 60 *( $elapsed_time->hours + ( 24* $elapsed_time->days )));
	my $estimated_total_seconds = $elapsed_seconds / $percent_complete;
	
	my $estimated_total_time = DateTime::Duration->new( 'seconds' => $estimated_total_seconds );
	my $estimated_finish_time = $start_time + $estimated_total_time;
	$estimated_finish_time->set_time_zone( 'America/Chicago' );
	
	return " Est. finish: " . $estimated_finish_time->month . "/" . $estimated_finish_time->day . " " . $estimated_finish_time->hour . ":" . $estimated_finish_time->minute . " (" . sprintf( "%.2f", $estimated_total_seconds / 3600) . " hrs)";
}

sub progress_bar {
	my $self = shift;
    my ( $got, $total, $width, $char ) = @_;
    $width ||= 25; $char ||= '=';
    my $num_width = length $total;
    sprintf ("|%-${width}s| Executed %${num_width}s actions of %s (%.2f%%) ", 
        $char x (($width-1)*$got/$total). '>', 
        $got, $total, 100*$got/+$total) . $self->expected_finish_string($got/$total) . "\r";
}

1;