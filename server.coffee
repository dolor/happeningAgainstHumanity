Db = require 'db'
Event = require 'event'
Plugin = require 'plugin'
Timer = require 'timer'
Util = require 'util'
Black = require 'black'
White = require 'white'
{tr} = require 'i18n'

handsize = 10
maxWinnerStackLength = 3

### Standard Functions ###

exports.onInstall = (config) !->
	if config?
		onConfig config

exports.onConfig = onConfig = (config) !->
	if config?
		# Do things
		if not Db.shared.get 'phase'
			exports.startgame()
	else
		# Defaults for template groups

exports.onUpgrade = !->
	log 'Upgrading..'
	# for r, winner of Db.shared.get 'winners'
	# 	log 'Upgrading round', r

exports.getTitle = ->
	tr("Happening against Humanity")

### Admin-panel functions, just for testing ###

exports.client_startgame = !->
	if Plugin.userIsAdmin()
		exports.startgame()

exports.client_nextround = !->
	if Plugin.userIsAdmin()
		nextround()
	
exports.client_closeround = !->
	if Plugin.userIsAdmin()
		exports.closeround()

exports.client_closevotes = !->
	if Plugin.userIsAdmin()
		exports.closevotes()

### Reminder Functions ###

exports.remindPlay = !->
	Event.create
		unit: 'game'
		text: tr('Do not forget to play a card!')
		include: Db.shared.get('waitingfor')

exports.remindVote = !->
	Event.create
		unit: 'game'
		text: tr('Do not forget to vote for the best card!')
		include: Db.shared.get('waitingfor')

### Phase-switch functions ###

exports.startgame = !->
	Db.shared.set 'questiondeck', [0..questionCards.length - 1] # [0..Black.cards.length - 1]
	Db.shared.set 'answerdeck', [0..answerCards.length - 1] # [0..White.cards.length - 1]
	Db.shared.set 'round', 0
	Db.shared.set 'score', {}
	Db.shared.set 'winners', {}
	Db.shared.set 'phase', 'starting'
 
	# can be used to add cards during a game with an upgrade
	Db.shared.set 'questiondecksize', questionCards.length # Black.cards.length
	Db.shared.set 'answerdecksize', answerCards.length # White.cards.length

	for uid in Plugin.userIds()
		Db.personal(uid).set 'playedcards', ''
		Db.personal(uid).set 'vote', ''
		Db.personal(uid).set 'showwinners', []

		hand = []
		for i in [0..handsize-1]
			hand.push drawAnswerCard()
		Db.personal(uid).set 'hand', hand
	
	Event.create
		unit: 'game'
		text: tr("A new game of 'Happening against Humanity' was started!")
		include: ['all']
	nextround()

# Initializes a new round
nextround = !->
	Timer.cancel()

	Db.shared.set 'round', Db.shared.get('round') + 1
	Db.shared.set 'phase', 'draw'
	Db.shared.set 'waitingfor', []
	Db.shared.set 'question', {play:0, text:''}
	Db.shared.set 'playedcards', []

	handempty = false # if anyone has <2 cards remaining, out of cards
	waitingfor = [] # also fill this here, we're looping over all users anyway.
	for userId in Plugin.userIds()
		log 'Clearing played cards for', userId
		Db.personal(userId).set 'playedcards', null
		waitingfor.push userId
		if !Db.personal(userId).get 'hand'
			Db.personal(userId).set 'hand', []
		else if Db.personal(userId).get('hand').length < 2
			handempty = true

	Db.shared.set 'waitingfor', waitingfor

	if (Db.shared.get 'answerdeck').length == 0
		log 'Pausing since we ran out of answer cards!'
		Db.shared.set 'phase', 'paused'

# Triggered by drawQuestion
startround = !->
	Timer.cancel()

	if (Db.shared.get 'questiondeck').length == 0
		log 'Pausing since we ran out of questions!'
		Db.shared.set 'phase', 'paused'
		return

	question = Db.shared.get 'question'
	
	Db.shared.set 'phase', 'play'

	duration = getRoundDuration(Date.now()/1000)
	Db.shared.set 'phase_end', (Date.now()/1000+duration)
	Timer.set (duration-3600)*1000, 'remindPlay'
	Timer.set duration*1000, 'closeround'

	eventObject = {
		unit: 'game'
		text: tr('Next Question: "')+question.text+'"'
	}
	if Plugin.userId()
		eventObject.exclude = [Plugin.userId()]
	else
		eventObject.include = ['all']

	Event.create eventObject

exports.closeround = !->
	Timer.cancel()

	log 'closeround'
	Db.shared.set 'phase', 'vote'
	play = (Db.shared.get 'question', 'play')
	playedcards = []
	waitingfor = []
	for userId in Plugin.userIds()
		waitingfor.push userId
		cards = Db.personal(userId).get('playedcards')
		log 'cards', cards
		if cards and Object.keys(cards).length == play
			Db.personal(userId).set 'activity', ((Db.personal(userId).get 'activity')|0) + 1

			log 'User $1s Played Cards: $2', userId, JSON.stringify(cards)
			hand = Db.personal(userId).get 'hand'
			for c,card of cards
				i = hand.indexOf card
				log 'Removing card at index', i
				hand.splice(i, 1)
			Db.personal(userId).set 'hand', hand
			playedcards.push cards

	if playedcards.length == 0
		for userId in Plugin.userIds()
			Db.personal(userId).set 'playedcards', null
		Event.create
			unit: 'game'
			text: tr('The round has ended, but nobody played a card. No winner!')
			include: ['all']

		nextround()
		return true
	
	Db.shared.set 'waitingfor', waitingfor
	Db.shared.set 'playedcards', playedcards

	duration = getRoundDuration(Date.now()/1000)
	log 'Duration2:', duration
	Db.shared.set 'phase_end', (Date.now()/1000+duration)
	Timer.set (duration-3600)*1000, 'remindVote'
	Timer.set duration*1000, 'closevotes'

	Event.create
		unit: 'game'
		text: tr('The cards have been played, it is time to vote for the winner!')
		include: ['all']

exports.closevotes = !->
	log 'closing votes and counting'

	# First, count which card got most votes (by text).
	votes = {}
	for userId in Plugin.userIds()
		log 'Counting answer for userId', userId
		if answer = JSON.stringify(Db.personal(userId).get('vote'))
			Db.personal(userId).set 'activity', ((Db.personal(userId).get 'activity')|0) + 1

			log 'Adding 1 tally for ' + answer, 'old:', votes[answer]
			# votes[answer] = (votes[answer]|0) + 1
			if !votes[answer]
				votes[answer] = [userId]
			else
				votes[answer].push(userId)
			log '    New:', votes[answer]
			Db.personal(userId).set 'vote', null
	
	# Next, determine who won. Necessary in case several get equal votes, the
	# winner will be chosen randomly.
	maxcount = -1
	wincards = []
	log 'votecount:', JSON.stringify(votes)
	for vote, users of votes
		log 'Vote:', JSON.stringify(vote)
		count = users.length
		if count == maxcount
			log 'Vote', vote, 'had just as much votes: ', users.length
			wincards.push vote
		else if count > maxcount
			log 'Vote', vote, 'had more votes: ', users.length
			wincards = [vote]
			maxcount = count

	# Next, see who played this card.
	winners = []
	log 'Checking to see who played winning card', wincards
	if wincards.length
		for wincard in wincards
			log 'Winning Card:', wincard
			for userId in Plugin.userIds()
				if playedcards = Db.personal(userId).get 'playedcards'
					log '  Comparing', JSON.stringify(playedcards), 'With', wincard
					log 'UserId:', userId
					if JSON.stringify(playedcards) == wincard
						log userId, 'Played Card', wincard
						winners.push userId
		# Finally, Reset played cards
		for userId in Plugin.userIds()
			Db.personal(userId).set 'playedcards', null
	else
		for userId in Plugin.userIds()
			Db.personal(userId).set 'playedcards', null

	if winners.length == 0
		Event.create
			unit: 'game'
			text: tr('The votes have closed, but nobody cast a vote. No winner!')
			include: ['all']
	else
		_wincards = []
		for wincard in wincards
			_wincards.push JSON.parse wincard
		wincards = _wincards
		
		log 'Winners:', winners
		log 'Wincards:', JSON.stringify(wincards)

		for winner in winners
			prevscore = Db.shared.get 'score', winner
			Db.shared.set 'score', winner, (0|prevscore) + 1

		round = Db.shared.get 'round'
		question = Db.shared.get 'question'
		all_winners = Db.shared.get 'winners'
		all_winners[round] =
			q: question
			a: wincards
			p: winners
			v: votes
		Db.shared.set 'winners', all_winners

		# Add these winners to everyone's showwinner stack.
		for userId in Plugin.userIds()
			if showwinners = Db.personal(userId).get 'showwinners'
				if showwinners.length == maxWinnerStackLength
					showwinners.shift()
			else
				showwinners = []
			showwinners.push round
			Db.personal(userId).set 'showwinners', showwinners

		winnerString = Util.getWinnerNames winners

		Event.create
			unit: 'game'
			text: tr('%1 won the round!', winnerString)
			include: ['all']

	nextround()


### Player Action functions ###

# Used to indicate the client has finished watching at the oldest winner in his stack
exports.client_popShowWinner = !->
	log 'User ', Plugin.userId(), ' checked out a winner!'
	showwinners = Db.personal(Plugin.userId()).get 'showwinners'
	showwinners.shift()
	Db.personal(Plugin.userId()).set 'showwinners', showwinners

exports.client_drawquestion = !->
	log 'Cancel timer'
	Timer.cancel()

	# Small 'hack' to allow removing questions from the deck during a game.
	question = {play: 0, text: ''}
	while question.text == '' or question.play == 0
		question = drawQuestionCard()

	log 'question', question
	Db.shared.set 'question', question
	startround()

exports.client_playcard = (p, card) !->
	hand = Db.personal(Plugin.userId()).get('hand')
	log 'User $1 played Card $2', Plugin.userId(), card
	if not card in hand
		log 'Invalid card'
		return false

	played = Db.personal(Plugin.userId()).get 'playedcards'
	if played
		for i, c of played
			if c == card
				played[i] = played[p]
	else
		played = {}
	played[p] = card

	log 'Player selected cards:', played
	Db.personal(Plugin.userId()).set 'playedcards', played
	waitingfor = []

	for userId in Plugin.userIds()
		for i in [0..Db.shared.get('question', 'play')-1]
			if userId in waitingfor then continue
			if not Db.personal(userId).get 'playedcards', i
				waitingfor.push userId

	Db.shared.set 'waitingfor', waitingfor
	if waitingfor.length == 0
		# Don't close immediately to give people a chance to change their mind.
		closedelay = 15
		Timer.set (closedelay * 1000), 'tryCloseround'

# Checks if everyone still played their cards and then closes the round
exports.tryCloseround = !->
	# If someone cancelled a card (not even possible at the moment), then the play
	# function would have updated this DB field as well, so simply check that.
	waitingfor = Db.shared.get 'waitingfor'

	if waitingfor.length == 0
		exports.closeround()

# returns 'false' if no cards remaining.
exports.client_drawcards = (cb) !->
	hand = Db.personal(Plugin.userId()).get 'hand'
	if hand.length >= handsize
		return false

	# Small 'hack' to be able to remove cards from the deck during a game.
	newcards = []
	while hand.length < handsize
		newcard = ''
		while newcard == ''
			newcard = drawAnswerCard()

		if newcard
			hand.push newcard
			Db.personal(Plugin.userId()).set 'hand', hand
			log 'Player '+Plugin.userId()+' drew card:', newcard
			newcards.push newcard

	cb.reply newcards

exports.client_vote = (wincards) !->
	Db.personal(Plugin.userId()).set 'vote', wincards

	everyonevoted = true
	waitingfor = []
	for userId in Plugin.userIds()
		if not Db.personal(userId).get 'vote'
			everyonevoted = false
			waitingfor.push userId

	Db.shared.set 'waitingfor', waitingfor
	if everyonevoted
		exports.closevotes()

exports.client_tutorialAnswer = (q, a) !->
	log 'Answered', q, a
	if q == 0
		if a == 0
			# Did not play before
			log 'Set activity to 0'
			Db.personal(Plugin.userId()).set 'activity', 0
		else if a == 1
			# Played before
			log 'Set activity to -1'
			Db.personal(Plugin.userId()).set 'activity', -1
	else if q == 1
		if a == 0
			# Does not want to see hints
			log 'Set activity to 10'
			Db.personal(Plugin.userId()).set 'activity', 10
		else if a == 1
			# Still wants help
			log 'Set activity to 0'
			Db.personal(Plugin.userId()).set 'activity', 0


### Helper Functions (e.g. Deck-Related) ###

drawQuestionCard = !->
	deck = Db.shared.get 'questiondeck'
	if not deck.length
		return false

	r = Math.floor(Math.random()*deck.length)
	cardId = deck[r]
	card = questionCards[cardId] # Black.cards[cardId]

	deck.splice(r, 1)
	Db.shared.set 'questiondeck', deck
	return card

drawAnswerCard = !->
	deck = Db.shared.get 'answerdeck'
	if not deck.length
		return false

	r = Math.floor(Math.random()*deck.length)
	cardId = deck[r]
	card = answerCards[cardId] # White.cards[cardId]

	deck.splice(r, 1)
	Db.shared.set 'answerdeck', deck
	return card

getRoundDuration = (currentTime) ->
	return false if !currentTime

	minRndLn = 4
	increment = 2
	duration = minRndLn*3600 # six hours
	while 22 <= (hrs = (new Date((currentTime+duration)*1000)).getHours()) or hrs <= 9
		duration += increment*3600

	duration

addComment = (comment) !->
	comment =
		t: 0|Plugin.time()
		u: 0
		s: true
		c: comment

	comments = Db.shared.createRef("comments", Db.shared.get 'roundcounter')
	max = comments.incr 'max'
	comments.set max, comment


### Cards ###

# Setting a question's play count to 0 removes it from future games, but won't break currently running games.
# Done this for some unclear questions, as well as some duplicate questions.
questionCards = [
	{play:1, text:"TSA guidelines now prohibit __________ on airplanes."},
	{play:1, text:"It's a pity that kids these days are all getting involved with __________."},
	{play:1, text:"In 1,000 years, when paper money is but a distant memory, __________ will be our currency."},
	{play:1, text:"Major League Baseball has banned __________ for giving players an unfair advantage."},
	{play:1, text:"What is Batman's guilty pleasure?"},
	{play:1, text:"Next from J.K. Rowling: Harry Potter and the Chamber of __________."},
	{play:1, text:"I'm sorry, Professor, but I couldn't complete my homework because of __________."},
	{play:1, text:"What did I bring back from Mexico?"},
	{play:1, text:"__________? There's an app for that."},
	{play:1, text:"__________. Betcha can't have just one!"},
	{play:1, text:"What's my anti-drug?"},
	{play:1, text:"While the United States raced the Soviet Union to the moon, the Mexican government funneled millions of pesos into research on __________."},
	{play:1, text:"In the new Disney Channel Original Movie, Hannah Montana struggles with __________ for the first time. "},
	{play:1, text:"What's my secret power?"},
	{play:1, text:"What's the new fad diet?"},
	{play:1, text:"What did Vin Diesel eat for dinner?"},
	{play:1, text:"When Pharaoh remained unmoved, Moses called down a Plague of __________."},
	{play:1, text:"How am I maintaining my relationship status?"},
	{play:1, text:"What's the crustiest?"},
	{play:1, text:"In L.A. County Jail, word is you can trade 200 cigarettes for __________."},
	{play:0, text:"After the earthquake, Sean Penn brought __________ to the people of Haiti."},
	{play:1, text:"Instead of coal, Santa now gives the bad children __________."},
	{play:1, text:"Life for American Indians was forever changed when the White Man introduced them to __________."},
	{play:1, text:"What's Teach for America using to inspire inner city students to succeed?"},
	{play:1, text:"Maybe she's born with it. Maybe it's __________."},
	{play:1, text:"In Michael Jackson's final moments, he thought about __________."},
	{play:1, text:"White people like __________."},
	{play:1, text:"Why do I hurt all over?"},
	{play:1, text:"A romantic, candlelit dinner would be incomplete without __________."},
	{play:1, text:"What will I bring back in time to convince people that I am a powerful wizard?"},
	{play:0, text:"BILLY MAYS HERE FOR __________."},
	{play:1, text:"The class field trip was completely ruined by __________."},
	{play:1, text:"What's a girl's best friend?"},
	{play:1, text:"Dear Abby, I'm having some trouble with __________ and would like your advice."},
	{play:1, text:"When I am President of the United States, I will create the Department of __________."},
	{play:1, text:"What are my parents hiding from me?"},
	{play:1, text:"What never fails to liven up the party?"},
	{play:1, text:"What gets better with age?"},
	{play:1, text:"__________: Good to the last drop."},
	{play:1, text:"I got 99 problems but __________ ain't one."},
	{play:1, text:"__________. It's a trap!"},
	{play:1, text:"MTV's new reality show features eight washed-up celebrities living with __________."},
	{play:1, text:"What would grandma find disturbing, yet oddly charming?"},
	{play:1, text:"What's the most emo?"},
	{play:1, text:"During sex, I like to think about __________."},
	{play:1, text:"What ended my last relationship?"},
	{play:1, text:"What's that sound?"},
	{play:1, text:"__________. That's how I want to die."},
	{play:1, text:"Why am I sticky?"},
	{play:1, text:"What's the next Happy Meal toy?"},
	{play:1, text:"What's there a ton of in heaven?"},
	{play:1, text:"I do not know with what weapons World War III will be fought, but World War IV will be fought with __________."},
	{play:1, text:"What will always get you laid?"},
	{play:1, text:"__________: Kid-tested, mother-approved."},
	{play:1, text:"Why can't I sleep at night?"},
	{play:1, text:"What's that smell?"},
	{play:1, text:"What helps Obama unwind?"},
	{play:1, text:"This is the way the world ends / This is the way the world ends / Not with a bang but with __________."},
	{play:1, text:"Coming to Broadway this season, __________: The Musical."},
	{play:1, text:"Anthropologists have recently discovered a primitive tribe that worships __________."},
	{play:1, text:"But before I kill you, Mr. Bond, I must show you __________."},
	{play:1, text:"Studies show that lab rats navigate mazes 50% faster after being exposed to __________."},
	{play:1, text:"Next on ESPN2: The World Series of __________."},
	{play:1, text:"When I am a billionaire, I shall erect a 50-foot statue to commemorate __________."},
	{play:1, text:"In an attempt to reach a wider audience, the Smithsonian Museum of Natural History has opened an interactive exhibit on __________."},
	{play:1, text:"War! What is it good for?"},
	{play:1, text:"What gives me uncontrollable gas?"},
	{play:1, text:"What do old people smell like?"},
	{play:0, text:"What am I giving up for Lent?"},
	{play:1, text:"Alternative medicine is now embracing the curative powers of __________."},
	{play:1, text:"What did the US airdrop to the children of Afghanistan?"},
	{play:0, text:"What does Dick Cheney prefer?"},
	{play:1, text:"During Picasso's often-overlooked Brown Period, he produced hundreds of paintings of __________."},
	{play:1, text:"What don't you want to find in your Chinese food?"},
	{play:1, text:"I drink to forget __________."},
	{play:1, text:"__________. High five, bro."},
	{play:1, text:"He who controls __________ controls the world."},
	{play:1, text:"The CIA now interrogates enemy agents by repeatedly subjecting them to __________."},
	{play:1, text:"In Rome, there are whisperings that the Vatican has a secret room devoted to __________."},
	{play:1, text:"Science will never explain the origin of __________."},
	{play:1, text:"When all else fails, I can always masturbate to __________."},
	{play:1, text:"I learned the hard way that you can't cheer up a grieving friend with __________."},
	{play:1, text:"In its new tourism campaign, Detroit proudly proclaims that it has finally eliminated __________."},
	{play:1, text:"The socialist governments of Scandinavia have declared that access to __________ is a basic human right."},
	{play:1, text:"In his new self-produced album, Kanye West raps over the sounds of __________."},
	{play:1, text:"What's the gift that keeps on giving?"},
	{play:1, text:"This season on Man vs. Wild, Bear Grylls must survive in the depths of the Amazon with only __________ and his wits. "},
	{play:1, text:"When I pooped, what came out of my butt?"},
	{play:1, text:"In the distant future, historians will agree that __________ marked the beginning of America's decline."},
	{play:1, text:"What has been making life difficult at the nudist colony?"},
	{play:1, text:"And I would have gotten away with it, too, if it hadn't been for __________."},
	{play:1, text:"What brought the orgy to a grinding halt?"},
	{play:0, text:"__________. High five, bro."},
	{play:0, text:"TSA guidelines now prohibit __________ on airplanes."},
	{play:0, text:"It's a pity that kids these days are all getting involved with __________."},
	{play:0, text:"In 1,000 years, when paper money is but a distant memory, __________ will be our currency."},
	{play:0, text:"Major League Baseball has banned __________ for giving players an unfair advantage."},
	{play:0, text:"What is Batman's guilty pleasure?"},
	{play:0, text:"Next from J.K. Rowling: Harry Potter and the Chamber of __________."},
	{play:0, text:"I'm sorry, Professor, but I couldn't complete my homework because of __________."},
	{play:0, text:"What did I bring back from Mexico?"},
	{play:0, text:"__________? There's an app for that."},
	{play:0, text:"Betcha can't have just one!"},
	{play:0, text:"What's my anti-drug?"},
	{play:0, text:"While the United States raced the Soviet Union to the moon, the Mexican government funneled millions of pesos into research on __________."},
	{play:0, text:"In the new Disney Channel Original Movie, Hannah Montana struggles with __________ for the first time."},
	{play:0, text:"What's my secret power?"},
	{play:0, text:"What's the new fad diet?"},
	{play:0, text:"What did Vin Diesel eat for dinner?"},
	{play:0, text:"When Pharaoh remained unmoved, Moses called down a Plague of __________."},
	{play:0, text:"How am I maintaining my relationship status?"},
	{play:0, text:"What's the crustiest?"},
	{play:1, text:"When I'm in prison, I'll have __________ smuggled in."},
	{play:0, text:"After Hurricane Katrina, Sean Penn brought __________ to the people of New Orleans."},
	{play:0, text:"Instead of coal, Santa now gives the bad children __________."},
	{play:0, text:"Life was difficult for cavemen before __________."},
	{play:0, text:"What's Teach for America using to inspire inner city students to succeed?"},
	{play:1, text:"Who stole the cookies from the cookie jar?"},
	{play:0, text:"In Michael Jackson's final moments, he thought about __________."},
	{play:0, text:"White people like __________."},
	{play:0, text:"Why do I hurt all over?"},
	{play:0, text:"A romantic candlelit dinner would be incomplete without __________."},
	{play:0, text:"What will I bring back in time to convince people that I am a powerful wizard?"},
	{play:0, text:"BILLY MAYS HERE FOR __________."},
	{play:0, text:"The class field trip was completely ruined by __________."},
	{play:0, text:"What's a girl's best friend?"},
	{play:1, text:"I wish I hadn't lost the instruction manual for __________."},
	{play:0, text:"When I am President of the United States, I will create the Department of __________."},
	{play:0, text:"What are my parents hiding from me?"},
	{play:0, text:"What never fails to liven up the party?"},
	{play:0, text:"What gets better with age?"},
	{play:0, text:"__________: good to the last drop."},
	{play:0, text:"I got 99 problems but __________ ain't one."},
	{play:0, text:"It's a trap!"},
	{play:0, text:"MTV's new reality show features eight washed-up celebrities living with __________."},
	{play:0, text:"What would grandma find disturbing, yet oddly charming?"},
	{play:0, text:"What's the most emo?"},
	{play:0, text:"During sex, I like to think about __________."},
	{play:0, text:"What ended my last relationship?"},
	{play:0, text:"What's that sound?"},
	{play:0, text:"__________. That's how I want to die."},
	{play:0, text:"Why am I sticky?"},
	{play:0, text:"What's the next Happy MealÂ® toy?"},
	{play:0, text:"What's there a ton of in heaven?"},
	{play:0, text:"I do not know with what weapons World War III will be fought, but World War IV will be fought with __________."},
	{play:0, text:"What will always get you laid?"},
	{play:0, text:"__________: kid tested, mother approved."},
	{play:0, text:"Why can't I sleep at night?"},
	{play:0, text:"What's that smell?"},
	{play:0, text:"What helps Obama unwind?"},
	{play:0, text:"This is the way the world ends \ This is the way the world ends \ Not with a bang but with __________."},
	{play:0, text:"Coming to Broadway this season, __________: The Musical."},
	{play:0, text:"Anthropologists have recently discovered a primitive tribe that worships __________."},
	{play:0, text:"But before I kill you, Mr. Bond, I must show you __________."},
	{play:0, text:"Studies show that lab rats navigate mazes 50% faster after being exposed to __________."},
	{play:1, text:"Due to a PR fiasco, Walmart no longer offers __________."},
	{play:0, text:"When I am a billionaire, I shall erect a 50-foot statue to commemorate __________."},
	{play:0, text:"In an attempt to reach a wider audience, the Smithsonian Museum of Natural History has opened an interactive exhibit on __________."},
	{play:0, text:"War! What is it good for?"},
	{play:0, text:"What gives me uncontrollable gas?"},
	{play:0, text:"What do old people smell like?"},
	{play:1, text:"Sorry everyone, I just __________."},
	{play:0, text:"Alternative medicine is now embracing the curative powers of __________."},
	{play:1, text:"The U.S. has begun airdropping __________ to the children of Afghanistan."},
	{play:0, text:"What does Dick Cheney prefer?"},
	{play:0, text:"During Picasso's often-overlooked Brown Period, he produced hundreds of paintings of __________."},
	{play:0, text:"What don't you want to find in your Chinese food?"},
	{play:0, text:"I drink to forget __________."},
	{play:2, text:"That's right, I killed __________. How, you ask? __________."},
	{play:2, text:"And the Academy Award for __________ goes to __________."}
	{play:2, text:"For my next trick, I will pull __________ out of __________."}
	{play:2, text:"In his new summer comedy, Rob Schneider is __________ trapped in the body of __________."}
	{play:2, text:"When I was tripping on acid, __________ turned into __________."}
	{play:2, text:"__________ is a slippery slope that leads to __________."}
	{play:2, text:"In a world ravaged by __________, our only solace is __________."}
	{play:2, text:"In M. Night Shyamalan's new movie, Bruce Willis discovers that __________ had really been __________ all along."}
	{play:2, text:"I never truly understood __________ until I encountered __________."}
	{play:2, text:"Rumor has it that Vladimir Putin's favorite dish is __________ stuffed with __________."}
	{play:2, text:"LifetimeÂ® presents __________, the story of __________."}
	{play:2, text:"What's the next superhero/sidekick duo?"}
]

answerCards = [
	"A Gypsy curse.",
	"A moment of silence." ,
	"A sausage festival." ,
	"An honest cop with nothing left to lose." ,
	"Famine." ,
	"Flesh-eating bacteria." ,
	"Flying sex snakes." ,
	"Not giving a shit about the Third World." ,
	"Sexting." ,
	"Shapeshifters." ,
	"Porn stars." ,
	"72 virgins." ,
	"A drive-by shooting." ,
	"A time travel paradox." ,
	"Authentic Mexican cuisine." ,
	"Bling." ,
	"Consultants." ,
	"Crippling debt." ,
	"Daddy issues." ,
	"The Donald Trump Seal of Approval™." ,
	"Dropping a chandelier on your enemies and riding the rope up." ,
	"Former President George W. Bush.",
	"Full frontal nudity." ,
	"Hormone injections." ,
	"Laying an egg." ,
	"Getting naked and watching Nickelodeon.",
	"Pretending to care.",
	"Public ridicule.",
	"Sharing needles.",
	"Boogers.",
	"The inevitable heat death of the universe.",
	"The miracle of childbirth.",
	"The Rapture.",
	"Whipping it out.",
	"White privilege.",
	"Wifely duties.",
	"The Hamburglar.",
	"AXE Body Spray.",
	"The Blood of Christ.",
	"Horrifying laser hair removal accidents.",
	"BATMAN!!!",
	"Agriculture.",
	"A robust mongoloid.",
	"Natural selection.",
	"Coat hanger abortions.",
	"Eating all of the cookies before the AIDS bake-sale.",
	"Michelle Obama's arms.",
	"The World of Warcraft.",
	"Swooping.",
	"Obesity.",
	"A homoerotic volleyball montage.",
	"Lockjaw.",
	"A mating display.",
	"Testicular torsion.",
	"All-you-can-eat shrimp for $4.99.",
	"Domino's™ Oreo™ Dessert Pizza.",
	"Kanye West.",
	"Hot cheese.",
	"Raptor attacks.",
	"Taking off your shirt.",
	"Smegma.",
	"Alcoholism.",
	"A middle-aged man on roller skates.",
	"The Care Bear Stare.",
	"Bingeing and purging.",
	"Oversized lollipops.",
	"Self-loathing.",
	"Children on leashes.",
	"Half-assed foreplay.",
	"The Holy Bible.",
	"German dungeon porn.",
	"Being on fire.",
	"Teenage pregnancy.",
	"Gandhi.",
	"Leaving an awkward voicemail.",
	"Uppercuts.",
	"Customer service representatives.",
	"An erection that lasts longer than four hours.",
	"My genitals.",
	"Picking up girls at the abortion clinic.",
	"Science.",
	"Not reciprocating oral sex.",
	"Flightless birds.",
	"A good sniff.",
	"Waterboarding.",
	"A balanced breakfast.",
	"Historically black colleges.",
	"Actually taking candy from a baby.",
	"The Make-A-Wish Foundation.",
	"A clandestine butt scratch.",
	"Passive-aggressive Post-it notes.",
	"The Chinese gymnastics team.",
	"Switching to Geico.",
	"Peeing a little bit.",
	"Home video of Oprah sobbing into a Lean Cuisine.",
	"Nocturnal emissions.",
	"The Jews.",
	"My humps.",
	"Powerful thighs.",
	"Hah! Beer!",
	"Happening",
	"Winking at old people.",
	"Mr. Clean, right behind you.",
	"A gentle caress of the inner thigh.",
	"Sexual tension.",
	"The forbidden fruit.",
	"Skeletor.",
	"Fancy Feast.",
	"Being rich.",
	"Sweet, sweet vengeance.",
	"Republicans.",
	"A gassy antelope.",
	"Natalie Portman.",
	"Copping a feel.",
	"Kamikaze pilots.",
	"Sean Connery.",
	"The homosexual agenda.",
	"The hardworking Mexican.",
	"A falcon with a cap on its head.",
	"Altar boys.",
	"The Kool-Aid Man.",
	"Getting so angry that you pop a boner.",
	"Free samples.",
	"A big hoopla about nothing.",
	"Doing the right thing.",
	"The Three-Fifths compromise.",
	"Lactation.",
	"World peace.",
	"RoboCop.",
	"Chutzpah.",
	"Justin Bieber.",
	"Oompa-Loompas.",
	"Inappropriate yodeling.",
	"Puberty.",
	"Ghosts.",
	"An asymmetric boob job.",
	"Vigorous jazz hands.",
	"Fingering.",
	"Glenn Beck catching his scrotum on a curtain hook.",
	"GoGurt.",
	"Police brutality.",
	"John Wilkes Booth.",
	"Preteens.",
	"Scalping.",
	"Stifling a giggle at the mention of Hutus and Tutsis.",
	"Tweeting.",
	"Darth Vader.",
	"A sad handjob.",
	"Exactly what you'd expect.",
	"Expecting a burp and vomiting on the floor.",
	"Adderall™.",
	"Embryonic stem cells.",
	"Tasteful sideboob.",
	"Panda sex.",
	"An icepick lobotomy.",
	"Tom Cruise.",
	"Mouth herpes.",
	"Sperm whales.",
	"Homeless people.",
	"Third base.",
	"Incest.",
	"Pac-Man uncontrollably guzzling cum.",
	"A mime having a stroke.",
	"Hulk Hogan.",
	"God.",
	"Scrubbing under the folds.",
	"Golden showers.",
	"Emotions.",
	"Licking things to claim them as your own.",
	"Pabst Blue Ribbon.",
	"The placenta.",
	"Spontaneous human combustion.",
	"Friends with benefits.",
	"Finger painting.",
	"Old-people smell.",
	"Dying of dysentery.",
	"My inner demons.",
	"A Super Soaker™ full of cat pee.",
	"Aaron Burr.",
	"Cuddling.",
	"The chronic.",
	"Cockfights.",
	"Friendly fire.",
	"Ronald Reagan.",
	"A disappointing birthday party.",
	"A sassy black woman.",
	"Mathletes.",
	"A tiny horse.",
	"William Shatner.",
	"Riding off into the sunset.",
	"An M. Night Shyamalan plot twist.",
	"Jew-fros.",
	"Mutually-assured destruction.",
	"Pedophiles.",
	"Yeast.",
	"Grave robbing.",
	"Eating the last known bison.",
	"Catapults.",
	"Poor people.",
	"Forgetting the Alamo.",
	"The Hustle.",
	"The Force.",
	"Wiping her butt.",
	"Intelligent design.",
	"Loose lips.",
	"AIDS.",
	"Pictures of boobs.",
	"The Übermensch.",
	"Sarah Palin.",
	"American Gladiators.",
	"Getting really high.",
	"Scientology.",
	"Penis envy.",
	"Praying the gay away.",
	"Frolicking.",
	"Two midgets shitting into a bucket.",
	"The KKK.",
	"Genghis Khan.",
	"Crystal meth.",
	"Serfdom.",
	"Stranger danger.",
	"A Bop It™.",
	"Shaquille O'Neal's acting career.",
	"Prancing.",
	"Vigilante justice.",
	"Overcompensation.",
	"Pixelated bukkake.",
	"A lifetime of sadness.",
	"Racism.",
	"Dwarf tossing.",
	"Sunshine and rainbows.",
	"A monkey smoking a cigar.",
	"Flash flooding.",
	"Lance Armstrong's missing testicle.",
	"Dry heaving.",
	"The terrorists.",
	"Britney Spears at 55.",
	"Attitude.",
	"Breaking out into song and dance.",
	"Leprosy.",
	"Gloryholes.",
	"Nipple blades.",
	"The heart of a child.",
	"Puppies!",
	"Waking up half-naked in a Denny's parking lot.",
	"Dental dams.",
	"Toni Morrison's vagina.",
	"The taint; the grundle; the fleshy fun-bridge.",
	"Active listening.",
	"Ethnic cleansing.",
	"The Little Engine That Could.",
	"The invisible hand.",
	"Waiting ‘til marriage.",
	"Unfathomable stupidity.",
	"Euphoria™ by Calvin Klein.",
	"Re-gifting.",
	"Autocannibalism.",
	"Erectile dysfunction.",
	"My collection of high-tech sex toys.",
	"The Pope.",
	"White people.",
	"Tentacle porn.",
	"Glenn Beck convulsively vomiting as a brood of crab spiders hatches in his brain and erupts from his tear ducts.",
	"Too much hair gel.",
	"Seppuku.",
	"Same-sex ice dancing.",
	"Cheating in the Special Olympics.",
	"Charisma.",
	"Keanu Reeves.",
	"Sean Penn.",
	"Nickelback.",
	"A look-see.",
	"Pooping back and forth. Forever.",
	"Menstruation.",
	"Kids with ass cancer.",
	"A salty surprise.",
	"The South.",
	"The violation of our most basic human rights.",
	"YOU MUST CONSTRUCT ADDITIONAL PYLONS.",
	"Being fabulous.",
	"Necrophilia.",
	"Centaurs.",
	"Bill Nye the Science Guy.",
	"Black people.",
	"Chivalry.",
	"Lunchables™.",
	"Bitches.",
	"The profoundly handicapped.",
	"Heartwarming orphans.",
	"MechaHitler.",
	"Fiery poops.",
	"Another goddamn vampire movie.",
	"Tangled Slinkys.",
	"The true meaning of Christmas.",
	"Estrogen.",
	"A zesty breakfast burrito.",
	"That thing that electrocutes your abs.",
	"Passing a kidney stone.",
	"A bleached asshole.",
	"Michael Jackson.",
	"Cybernetic enhancements.",
	"Guys who don't call.",
	"Smallpox blankets.",
	"Masturbation.",
	"Classist undertones.",
	"Queefing.",
	"Concealing a boner.",
	"Edible underpants.",
	"Viagra.",
	"Soup that is too hot.",
	"Muhammad (Praise Be Unto Him).",
	"Surprise sex!",
	"Five-Dollar Footlongs™.",
	"Drinking alone.",
	"Dick fingers.",
	"Multiple stab wounds.",
	"Soiling oneself.",
	"Child abuse.",
	"Anal beads.",
	"Civilian casualties.",
	"Pulling out.",
	"Robert Downey, Jr.",
	"Horse meat.",
	"A really cool hat.",
	"Kim Jong-il.",
	"A stray pube.",
	"Jewish fraternities.",
	"The token minority.",
	"Doin' it in the butt.",
	"Feeding Rosie O'Donnell.",
	"Teaching a robot to love.",
	"A can of whoop-ass.",
	"A windmill full of corpses.",
	"Count Chocula.",
	"Wearing underwear inside-out to avoid doing laundry.",
	"A death ray.",
	"The glass ceiling.",
	"A cooler full of organs.",
	"The American Dream.",
	"Keg stands.",
	"When you fart and a little bit comes out.",
	"Take-backsies.",
	"Dead babies.",
	"Foreskin.",
	"Saxophone solos.",
	"Italians.",
	"A fetus.",
	"Firing a rifle into the air while balls deep in a squealing hog.",
	"Dick Cheney.",
	"Amputees.",
	"Eugenics.",
	"My relationship status.",
	"Christopher Walken.",
	"Bees?",
	"Harry Potter erotica.",
	"College.",
	"Getting drunk on mouthwash.",
	"Nazis.",
	"8 oz. of sweet Mexican black-tar heroin.",
	"Stephen Hawking talking dirty.",
	"Dead parents.",
	"Object permanence.",
	"Opposable thumbs.",
	"Racially-biased SAT questions.",
	"Jibber-jabber.",
	"Chainsaws for hands.",
	"Nicolas Cage.",
	"Child beauty pageants.",
	"Explosions.",
	"Sniffing glue.",
	"Glenn Beck being harried by a swarm of buzzards.",
	"Repression.",
	"Roofies.",
	"My vagina.",
	"Assless chaps.",
	"A murder most foul.",
	"Giving 110 percent.",
	"Her Royal Highness, Queen Elizabeth II.",
	"The Trail of Tears.",
	"Being marginalized.",
	"Goblins.",
	"Hope.",
	"The Rev. Dr. Martin Luther King, Jr.",
	"A micropenis.",
	"My soul.",
	"A hot mess.",
	"Vikings.",
	"Hot people.",
	"Seduction.",
	"An Oedipus complex.",
	"Geese.",
	"Global warming.",
	"New Age music.",
	"Hot Pockets.",
	"Making a pouty face.",
	"Vehicular manslaughter.",
	"Women's suffrage.",
	"A defective condom.",
	"Judge Judy.",
	"African children.",
	"The Virginia Tech Massacre.",
	"Barack Obama.",
	"Asians who aren't good at math.",
	"Elderly Japanese men.",
	"Exchanging pleasantries.",
	"Heteronormativity.",
	"Parting the Red Sea.",
	"Arnold Schwarzenegger.",
	"Road head.",
	"Spectacular abs.",
	"Figgy pudding.",
	"A mopey zoo lion.",
	"A bag of magic beans.",
	"Poor life choices.",
	"My sex life.",
	"Auschwitz.",
	"A snapping turtle biting the tip of your penis.",
	"A thermonuclear detonation.",
	"The clitoris.",
	"The Big Bang.",
	"Land mines.",
	"Friends who eat all the snacks.",
	"Goats eating cans.",
	"The Dance of the Sugar Plum Fairy.",
	"Jerking off into a pool of children's tears.",
	"Man meat.",
	"Me time.",
	"The Underground Railroad.",
	"Poorly-timed Holocaust jokes.",
	"A sea of troubles.",
	"Lumberjack fantasies.",
	"Morgan Freeman's voice.",
	"Women in yogurt commercials.",
	"Natural male enhancement.",
	"Being a motherfucking sorcerer.",
	"Genital piercings.",
	"Passable transvestites.",
	"Sexy pillow fights.",
	"Balls.",
	"Grandma.",
	"Friction.",
	"Party poopers.",
	"Farting and walking away.",
	"Being a dick to children.",
	"Booby-trapping the house to foil burglars.",
	"The Tempur-Pedic Swedish Sleep System™.",
	"Dying.",
	"Hurricane Katrina.",
	"The gays.",
	"The folly of man.",
	"Men.",
	"The Amish.",
	"Pterodactyl eggs.",
	"Team-building exercises.",
	"A brain tumor.",
	"Cards Against Humanity.",
	"Fear itself.",
	"Lady Gaga.",
	"The milk man.",
	"A foul mouth.",
	"A big black dick.",
	"A beached whale.",
	"A bloody pacifier.",
	"A crappy little hand.",
	"A low standard of living.",
	"A nuanced critique.",
	"Panty raids.",
	"A passionate Latino lover.",
	"A rival dojo.",
	"A web of lies.",
	"A woman scorned.",
	"Clams.",
	"Apologizing.",
	"Appreciative snapping.",
	"Neil Patrick Harris.",
	"Beating your wives.",
	"Being a dinosaur.",
	"Shaft.",
	"Bosnian chicken farmers.",
	"Nubile slave boys.",
	"Carnies.",
	"Coughing into a vagina.",
	"Suicidal thoughts.",
	"Dancing with a broom.",
	"Deflowering the princess.",
	"Dorito breath.",
	"Eating an albino.",
	"Enormous Scandinavian women.",
	"Fabricating statistics.",
	"Finding a skeleton.",
	"Gandalf.",
	"Genetically engineered super-soldiers.",
	"George Clooney's musk.",
	"Getting abducted by Peter Pan.",
	"Getting in her pants, politely.",
	"Gladiatorial combat.",
	"Good grammar.",
	"Hipsters.",
	"Historical revisionism.",
	"Insatiable bloodlust.",
	"Jafar.",
	"Jean-Claude Van Damme.",
	"Just the tip.",
	"Mad hacky-sack skills.",
	"Leveling up.",
	"Literally eating shit.",
	"Making the penises kiss.",
	"Media coverage.",
	"Medieval Times Dinner and Tournament.",
	"Moral ambiguity.",
	"My machete.",
	"One thousand Slim Jims.",
	"Ominous background music.",
	"Overpowering your father.",
	"Pistol-whipping a hostage.",
	"Quiche.",
	"Quivering jowls.",
	"Revenge fucking.",
	"Ripping into a man's chest and pulling out his still-beating heart.",
	"Ryan Gosling riding in on a white horse.",
	"Santa Claus.",
	"Scrotum tickling.",
	"Sexual humiliation.",
	"Sexy Siamese twins.",
	"Slow motion.",
	"Space muffins.",
	"Statistically validated stereotypes.",
	"Sudden Poop Explosion Disease.",
	"The boners of the elderly.",
	"The economy.",
	"The Fanta girls.",
	"The Gulags.",
	"The harsh light of day.",
	"The hiccups.",
	"The shambling corpse of Larry King.",
	"The four arms of Vishnu.",
	"Being a busy adult with many important things to do.",
	"Tripping balls.",
	"Words, words, words.",
	"Zeus's sexual appetites."
]
