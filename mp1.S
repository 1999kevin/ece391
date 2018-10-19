
# mp1.S - missile-command version
# Good luck, and have fun!

.data
	
    # Constants for accessing the fields of a struct missile, 
    # struct missile is defined in rtc.h and mp1.h

	NEXT 	  = 0
	X	  = 4
	Y	  = 8
	VX	  = 12
	VY	  = 16
	DEST_X	  = 20
	DEST_Y	  = 24
	EXPLODED  = 28
	C	  = 32
	

    # Character to draw for an explosion - '@'

	EXPLOSION = 64


# Data shared between this file and rtc.c helper functions

# This '.globl' directive makes these symbols visible externally
.globl mp1_missile_list, base_alive, mp1_score

mp1_missile_list:	.long 0x0	# Head of list pointer
base_alive:		.long 0x0	# Array of 3 bytes, plus a padding byte
mp1_score:		.long 0x0	# Player's current score


# Data private to this  file

base_pic:     	    .string "/^^^\\"	# Picture of a live base
dead_base_pic: 	    .string "xxxxx"	# Picture of a dead base
crosshairs_x:		.long 0x0	# X-position of the crosshairs
crosshairs_y:		.long 0x0	# Y-position of the crosshairs
status:    			.long 0x0

.text

# void mp1_poke(void);
# You can use this function to write to video memory.
#
# Interface: Register-based arguments (not C-style)
#    Inputs: %cl  - The byte you wish to write
#            %eax - Offset from the start of video memory that you wish
#                   to write to
#   Outputs: Text-mode video screen is written to at location %eax with
#            the byte in %cl
# Registers: Clobbers EDX

mp1_poke:
		pushl %edx
		movl    vmem_base_addr(,1),%edx
		movb    %cl,(%edx,%eax,1)
		popl %edx
		ret

#   ----------------- Exported functions ---------------------

# void mp1_rtc_tasklet(unsigned long garbage);
# Performs three tasks:
#	(1) updates the list of missiles (implement this in update_missiles,
#           below, and call it from here).
#	(2) Redraw the bases - they may have been overwritten with missiles
#	(3) Redraw the crosshairs - it may have been overwritten with missiles
# Inputs   : none
# Outputs  : none
# Registers: Standard C calling convention

.globl mp1_rtc_tasklet
mp1_rtc_tasklet:
		pushl %ebp
		movl %esp, %ebp
		pushl %ebx
		pushl %esi
		pushl %edi
		
		pushl %eax    #eax will be used to figure out whether we will call mp1_notify_user
		#divide this big function into three part
		call update_missiles
		call redraw_cities
		call redraw_crosshairs
		#judge whether I need to call mp1_notify_user from eax
		cmpl $0,%eax
		je tasklet_done
		call mp1_notify_user
		
	tasklet_done:
		popl %eax
		popl %edi
		popl %esi 
		popl %ebx
		leave
		ret

# int mp1_ioctl(unsigned long arg, unsigned int cmd)
# The dispatch function for the MP1 ioctls - should use the cmd argument
# and a jumptable to execute one of the specific ioctls implemented below.
# Inputs   : unsigned long arg - parameter to the mp1_ioctl_....
#          : unsigned int cmd  - specifies which mp1_ioctl_... function 
#          :                     to execute
# Outputs  : Returns an integer - depends on which ioctl() function is called
# Registers: Standard C calling convention

.globl mp1_ioctl
mp1_ioctl:
		#load the input into eax
		movl 8(%esp),%eax
		#determine whether it is a valid cmd
		cmpl $4, %eax
		ja invalid_cmd
		cmpl $0, %eax
		jb invalid_cmd

		jmp *jump_table(,%eax,4)

	invalid_cmd:		# return -1 if it is not a valid cmd
		movl $-1, %eax			
		ret


jump_table:
		.long mp1_ioctl_startgame,mp1_ioctl_addmissile,mp1_ioctl_movexhairs,mp1_ioctl_getstatus,mp1_ioctl_endgame


# ----------------- Functions private to this file -------------------

#int update_missiles():
#this function works as a part of tasklet and update the missiles 
#input: no input
#output: a flag about whether we should call mp1_notify_user, stored in eax
#Registers: Standard C calling convention


update_missiles:
		#store every callee register
		pushl %ebp
		movl %esp, %ebp
		pushl %ebx
		pushl %esi
		pushl %edi
		pushl %edx 
		pushl %ecx
		#let ecx points to the head of the missile_list
		movl mp1_missile_list, %ecx	

	loop_begin:
		cmpl $0, %ecx
		je loop_done

		#calculate the position of missile and remove the missile from the screen firstly
		pushl %eax                #eax is caller save
		pushl %ecx
		call missile_position
		movb $32, %cl				#the ASCII of space is 32
		call mp1_poke
		popl %ecx
		popl %eax
	
	case1:  	#exploded == 0
		cmpl $0, EXPLODED(%ecx)
		jne check_bounding

		#update new x and y for this missile
		movl VX(%ecx),%edx
		addl %edx, X(%ecx)
		movl VY(%ecx),%edx
		addl %edx, Y(%ecx)
	
	check_bounding:  #check whether the missile is out of the screen
		cmpl $0x004fffff, X(%ecx)    #0x004fffff has 79 in the third 8-bits
		jg out_of_screen
		cmpl $0,X(%ecx)
		jl out_of_screen

		cmpl $0x0018ffff, Y(%ecx)    #0x0018ffff has 24 in the third 8-bits
		jg out_of_screen
		cmpl $0, Y(%ecx)
		jl out_of_screen
		jmp case2

	out_of_screen:		#the missile is out of the screen, so it should be removed
		call mp1_missile_remove
		jmp loop_done


	case2:# the missile is exploding or is going to explode
		cmpl $0,EXPLODED(%ecx)						#if EXPLODED > 0, the missile is exploding
		jne exploding

		#compare X and DEST_X, Y  and DEST_Y
		movl X(%ecx),%edx
		shrl $16,%edx				#if the X is different from the destination, go case3
		cmpl %edx, DEST_X(%ecx)		#compare the high 16 bits of X with DEST_X
		jne case3

		movl Y(%ecx),%edx					#if the Y is different from the destination, go case3
		shrl $16,%edx				#compare the high 16 bits of Y with DEST_Y
		cmpl %edx, DEST_Y(%ecx)
		jne case3

	exploding:						#   if reached its destination or is currently exploding
		pushl %eax
		pushl %edx
		pushl %ecx
		call missile_explode		#   return valuse is stored in eax
        movl %eax, %esi				##store the return value in esi
		
		
		popl %ecx
		popl %edx
		popl %eax
		movl EXPLODED(%ecx),%edx	#is exploding now and decrease by 1
		subl $1, %edx
		movl %edx,EXPLODED(%ecx)

		cmpl $0,%edx				# if the EXPLODED is 0 now, then remove the missile
		jne draw_exploding

		call mp1_missile_remove
		jmp one_missile_done      

	draw_exploding:
		pushl %eax					#eax is caller save for missile position
		pushl %ecx
		call missile_position      #calculate the offset and offset is in eax now
		movb $EXPLOSION,%cl
		call mp1_poke
		popl %ecx
		popl %eax
		jmp one_missile_done
		

	case3:							#the missile is moving to a new position
		pushl %eax
		pushl %ecx
		call missile_position		#calculate the position and draw it in the screen
		movb C(%ecx), %cl
		call mp1_poke
		popl %ecx
		popl %eax

	one_missile_done:
		movl NEXT(%ecx),%ecx		#one missile is over and move to the next missile
		jmp loop_begin


	loop_done:						#update_missile is done, pop all register
		movl %esi, %eax 
		popl %ecx
		popl %edx
		popl %edi
		popl %esi
		popl %ebx
		leave
		ret

#void redraw_cities():
#this function is the subpart of tasklet and is used to redraw the cities
#inputs: none
#outputs: none
#Registers: Standard C calling convention
redraw_cities:
		#save all callee register
		pushl %ebp
		movl %esp, %ebp
		pushl %esi
		pushl %ebx
		pushl %edi
		pushl %edx
		pushl %ecx

		#draw the first city				
		movl base_alive, %edx
		andl $0x000000ff, %edx				#check whether the last two bytes of base_alive is 0
		movl $18, %ecx						#load ecx with the leftmost of the fitst city 
		pushl %ecx							#push two parameter
		pushl %edx
		call draw_city						#call draw_city to draw it
		popl %edx
		popl %ecx

		#draw the second city
		movl base_alive, %edx				
		andl $0x0000ff00, %edx				#check whether the second last two bytes of base_alive is 0
		movl $38, %ecx						#load ecx with the leftmost of the second city 
		pushl %ecx							#push two parameter
		pushl %edx
		call draw_city						#call draw_city to draw it
		popl %edx
		popl %ecx

		#draw the third city
		movl base_alive, %edx				#check whether the third last two bytes of base_alive is 0
		andl $0x00ff0000, %edx
		movl $58, %ecx						#load ecx with the leftmost of the third city
		pushl %ecx							#push two parameter
		pushl %edx
		call draw_city						#call draw_city to draw it
		popl %edx
		popl %ecx

		#pop all callee register
		popl %ecx
		popl %edx
		popl %edi
		popl %ebx 
		popl %esi
		leave 
		ret


	
#void redraw_crosshairs():   
#this function is the third part of tasklet and is used to redraw the crosshairs
#input : none
#output: none
#Registers: Standard C calling convention
redraw_crosshairs:
		#push all callee register
		pushl %ebp
		movl %esp, %ebp
		pushl %eax
		pushl %ecx


		#calculate the position of the crosshairs : (Y*80 + X)*2		
		movl crosshairs_y, %eax
		imull $80, %eax					#the width is 80
		addl crosshairs_x, %eax
		imull $2, %eax

		movb $43, %cl    		#43 is ASCII code of '+'
		call mp1_poke
		
		##pop all callee register
		popl %ecx
		popl %eax
		leave
		ret


#int mp1_ioctl_startgame(unsigned long ignore):
#this function is used to initiate all variable used in taksklet
#input : the input variable is useless so ignore it
#output: none
#Registers: Standard C calling convention
mp1_ioctl_startgame:
		#push all callee register
		pushl %ebp				
		movl %esp, %ebp
		pushl %esi
		pushl %ebx
		pushl %edi
		
		#initiate all necessary variables
		movl $40, crosshairs_x				#set crosshairs in the middile of the screen
		movl $12, crosshairs_y	
		movl $0,mp1_score					#set the initial score is 0
		movl $0x00010101, base_alive		#set the three city is alive

		#pop all callee register
		popl %edi 
		popl %ebx
		popl %esi
		leave
		ret

		
#int mp1_ioctl_addmissile(struct missile* user_missile):
#the function is used to add a missile struction at the head of the missile list
#input: a pointer to a struct missile in user space
#output:0 if successful and -1 if fail
#Registers: Standard C calling convention
mp1_ioctl_addmissile:
		#push all callee register
		pushl %ebp
		movl %esp, %ebp
		pushl %esi
		pushl %ebx
		pushl %edi
		pushl %ecx
		pushl %edx

		movl $33,%edx 			#the size of one struct missile is 33
		movl 8(%ebp),%ecx		#load the pointer of the missile to be added in ecx
		pushl %ecx				#push all parameter and call the mallor function
		pushl %edx 
		call mp1_malloc   		#eax get the pointer to the new missile
		popl %edx 
		popl %ecx

		pushl %edx 				#push all parameter of mp1_copy_from_user
		pushl %ecx
		pushl %eax
		call mp1_copy_from_user			#now eax holds the return value from mo1_copy_from_user
		cmpl $0,%eax			#check whether it fail
		jne fail
		
		#add missile successfully, then add it at the head of the missile list
		popl %eax					#now eax get the pointer to the new missile		
		popl %ecx					
		popl %edx
		movl mp1_missile_list, %edx 
		movl %edx,NEXT(%eax)				
		movl %eax,mp1_missile_list
		movl $0,%eax				# return 0  
		jmp addmissile_done

	fail:# add missile wrong, so should free it 
		popl %eax					#now eax get the pointer to the new missile		
		popl %ecx
		popl %edx
		pushl %eax
		call mp1_free
		addl $4,%esp				
		movl $-1,%eax				#return -1

	addmissile_done:
		#pop all callee register
		popl %edx	
		popl %ecx 
		popl %edi 
		popl %ebx
		popl %esi
		leave
		ret

		
		
		
#int mp1_ioctl_movexhairs(unsigned long xhair_delta_packed):
#the function is used to move the crosshairs 
#input: a long integer which contains x(low 16-bits) and y(high 16-bits)
#output:0 
#Registers: Standard C calling convention			
mp1_ioctl_movexhairs:
		#push all callee register
		pushl %ebp
		movl %esp, %ebp
		pushl %esi
		pushl %ebx
		pushl %edi
		pushl %edx 
		pushl %ecx

		movl 8(%ebp),%edx   #let edx holds the paramater
		movl %edx,%ecx
		shll $16,%ecx   #now ecx holds the low 16 bit, which is x
		sarl $16, %ecx   #now edx holds the high 16 bit, which is y
		sarl $16, %edx      

		#now we need to calculate the position of the crosshairs, remove and redraw it
		movl crosshairs_y, %eax
		imull $80, %eax				#80 is the width 
		addl crosshairs_x, %eax
		imull $2, %eax

		#firsyly remove it from the original postion
		pushl %ecx
		movb $32, %cl		#the ASCII for space is 32
		call mp1_poke 
		popl %ecx

		#secondly calculate the correct position
		addl crosshairs_x, %ecx
		addl crosshairs_y, %edx

		#thirdly judge whether it is outside of the screen
		cmpl $79, %ecx		#79 is upper bound for x 
		jg X_too_large
		cmpl $0, %ecx		#0 is the lower bound for x
		jl X_too_small
		jmp judge_Y

		#focus x in the [0,79]
	X_too_large:
		movl $79, %ecx		
		jmp judge_Y
	X_too_small:
		movl $0, %ecx

	judge_Y:
		cmpl $24, %edx			#24 is upper bound for y 
		jg Y_too_large
		cmpl $0, %edx			#0 is the lower bound for y
		jl Y_too_small
		jmp draw_new_crosshairs

		#focus x in the [0,24]
	Y_too_large:
		movl $24, %edx
		jmp draw_new_crosshairs
	Y_too_small:
		movl $0, %edx

	draw_new_crosshairs:
		#need to calculate the position(Y*80 +X)*2
		movl %ecx, crosshairs_x
		movl %edx, crosshairs_y
		movl %edx, %eax
		imull $80, %eax				#80 is width
		addl %ecx, %eax
		imull $2, %eax
		pushl %ecx
		movb $43,%cl				#the ASCII of '+' is 43
		call mp1_poke
		popl %ecx

		#pop all callee register
		popl %ecx
		popl %edx 
		popl %edi 
		popl %ebx
		popl %esi
		leave 
		ret 


#int mp1_ioctl_getstatus(unsigned long* user_status):
#the function allows the user to retrieve the current score and the status of the three cities
#input: a pointer to a 32-bit integer in user space
#output:0 if successfullu and -1 if fails
#Registers: Standard C calling convention	
mp1_ioctl_getstatus:
		#push all callee register
		pushl %ebp
		movl %esp, %ebp
		pushl %esi
		pushl %ebx
		pushl %edi
		pushl %edx 
		pushl %ecx

		movl 8(%ebp),%edx   #firstly let edx hold the parameter 
		movl mp1_score, %ecx		#new ecx hold the score
		movl %ecx, status

		#next judge whether the three city is alive or dead
		movl base_alive, %eax
		andl $0x000000ff, %eax			#check whether the first city is alive or dead
		cmpl $0, %eax
		je check_second_city
		addl $0x00010000, status		#add 1 in the bit 16 
	
	check_second_city:
		movl base_alive, %eax			#check whether the second city is alive or dead
		andl $0x0000ff00, %eax
		cmpl $0, %eax
		je check_third_city			
		addl $0x00020000,status			#add 1 in the bit 17

	check_third_city:
		movl base_alive, %eax
		andl $0x00ff0000, %eax			#check whether the third city is alive or dead
		cmpl $0, %eax
		je copy_to_user
		addl $0x00040000,status			#add 1 in the bit 18

	copy_to_user:
		pushl $4						#the size of the date to be copied is 32 bit, which is 4 bytes
		pushl $status
		pushl %edx
		call mp1_copy_to_user
		addl $12,%esp  					#clean up the stack for mp1_copy_tp_user
		cmpl $0,%eax
		je getstatus_done
		movl $-1,%eax

	getstatus_done:
		#pop all callee register
		popl %ecx
		popl %edx 
		popl %edi 
		popl %ebx
		popl %esi
		leave 
		ret 

		
		
#int mp1_endgame(unsigned long ignore):
#the function \perform all the cleanup work
#input: input will be ignored
#output:none
#Registers: Standard C calling convention			
mp1_ioctl_endgame:
		#push all callee register
		pushl %ebp
		movl %esp, %ebp
		pushl %esi
		pushl %ebx
		pushl %edi
		pushl %edx

		movl mp1_missile_list, %eax			#let eax points to the beginning of the missile list
	free_loop:
		cmpl $0,mp1_missile_list
		je endgame_done
		movl mp1_missile_list, %eax			#let eax mp1_missile_list points to next missile and free this one
		movl NEXT(%eax),%edx
		movl %edx,mp1_missile_list
		pushl %edx
		pushl %eax
		call mp1_free						#call mp1_free to free this missile
		popl %eax
		popl %edx
		jmp free_loop

	endgame_done:
		#pop all callee register 
		movl $0,%eax
		popl %edx
		popl %edi 
		popl %ebx
		popl %esi
		leave 
		ret 
		
		
########################################my own helper function#####################################

#void mp1_missile_remove(missile* ptr): 
#this function is used to delete the missile who has the pointer of ptr
#input: ecx :the point to the missile we would like to delete
#output: none
##Registers: Standard C calling convention
mp1_missile_remove:
		#store all callee register
		pushl %ebp
		movl %esp, %ebp
		pushl %esi
		pushl %ebx
		pushl %edi
		pushl %edx
		pushl %eax
		
		#check whether it is a none pointer
		cmpl $0, %ecx
		je remove_done
		
		
		#check whether it is the first one
		movl mp1_missile_list, %edx			#edx points to the head of the missile_list
		cmpl %edx, %ecx
		jne remove_case2

	remove_case1: 	# ptr == head of mp1_missile_list
		movl NEXT(%ecx), %eax
		movl %eax, mp1_missile_list	
		pushl %eax
		pushl %edx
		pushl %ecx
		call mp1_free								
		popl %ecx				   			#clean the stack
		popl %edx
		popl %eax
		movl mp1_missile_list, %ecx	    	#let ecx point to mp1_missile_list again
		jmp remove_done

	remove_case2:	#find the previous missile point and save it in edx
		movl NEXT(%edx), %eax
		cmpl %eax, %ecx						#let edx is the previous one
		je free

		movl NEXT(%edx),%edx				#not find the previous missile, then check the next one
		jmp remove_case2

	free:			#free this missile
		movl NEXT(%ecx), %eax
		movl %eax, NEXT(%edx)				#let the next missile of the previous one of this points to the next one of this
		pushl %edx
		pushl %eax
		pushl %ecx							#free it
		call mp1_free
		popl %ecx						#clean the stack
		popl %eax
		popl %edx
		movl %edx, %ecx    					#let ecx point to the previous one
	
	remove_done:	#pop all callee register
		popl %eax
		popl %edx 
		popl %edi
		popl %ebx
		popl %esi
		leave
		ret



#int missile_position(missile* ptr):
# this function is use to find the position of the missile
#input: the point to the missile
#output: %eax, the offset from the start of video memory
# position will be (Y*80+X)*2, and eax should be caller save
##Registers: Standard C calling convention
missile_position:
		#push all callee register
		pushl %ebp
		movl %esp, %ebp
		pushl %esi
		pushl %ebx
		pushl %edi
		pushl %ecx
		pushl %edx

		# the position is just (Y*80+X)*2
		movl 8(%ebp),%ecx                #ecx is the point to the missile
		movl Y(%ecx),%edx
		shrl $16, %edx					#shift edx right for 16 bit because the high 16 bit is the location Y in the screen 
		imull $80,%edx
		movl X(%ecx),%eax
		shrl $16, %eax					#shift eax right for 16 bit because the high 16 bit is the location X in the screen 
		addl %edx,%eax
		imull $2,%eax

		#pop all callee register
		popl %edx 
		popl %ecx
		popl %edi
		popl %ebx
		popl %esi
		leave 
		ret




#void draw_city(int location, int status)
# this function is used to draw the city 
#input : status :the state of the city (0 - alive; 1 - destroyed)
#		 location : location of the left corner of the city
#output: none
##Registers: Standard C calling convention
draw_city:
		#push all callee register
		pushl %ebp	
		movl %esp, %ebp
		pushl %esi
		pushl %ebx
		pushl %edi
		pushl %eax
		pushl %edx
		pushl %ecx

		movl 8(%ebp), %edx     #edx figure out  whether the city is alive or destroyed
		movl 12(%ebp), %ecx    #ecx contains X of leftmost corner of the city

		#judge whether it is alive or destroyed and store the correct array in ebx
		cmpl $0, %edx
		jne is_alive	
		leal dead_base_pic, %edx
		jmp begin_to_draw_city

	is_alive:
		leal base_pic, %edx
	
	begin_to_draw_city:		#the offset should be (24*80 + x) *2
		movl $24, %eax		# the city is in the bottle of the screen so y = 24
		imull $80, %eax		# 80 is the width
		addl %ecx, %eax
		imull $2, %eax		# draw the second char( it is on the right of the previous one) 
		movb 0(%edx),%cl
		call mp1_poke
		addl $2,%eax		# draw the third char( it is on the right of the previous one) 
		movb 1(%edx),%cl
		call mp1_poke
		addl $2,%eax		# draw the fourth char( it is on the right of the previous one)
		movb 2(%edx),%cl
		call mp1_poke		
		addl $2,%eax		# draw the fifth char( it is on the right of the previous one)
		movb 3(%edx),%cl
		call mp1_poke	
		addl $2,%eax
		movb 4(%edx),%cl
		call mp1_poke

		#pop all callee register
		popl %ecx
		popl %edx
		popl %eax
		popl %edi
		popl %ebx
		popl %esi
		leave
		ret






























