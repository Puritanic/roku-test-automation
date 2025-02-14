sub init()
	logInfo("OnDeviceComponent init")
	m.task = m.top.createChild("RTA_OnDeviceComponentTask")
	m.task.observeFieldScoped("renderThreadRequest", "onRenderThreadRequestChange")
	m.task.control = "RUN"

	m.activeObserveFieldRequests = {}

	m.nodeReferences = {}
end sub

sub onRenderThreadRequestChange(event as Object)
	request = event.getData()
	setLogLevel(getStringAtKeyPath(request, "settings.logLevel"))
	logDebug("Received request: ", formatJson(request))

	requestType = request.type
	args = request.args
	request.timespan = createObject("roTimespan")

	response = Invalid
	if requestType = "callFunc" then
		response = processCallFuncRequest(args)
	else if requestType = "getFocusedNode" then
		response = processGetFocusedNodeRequest(args)
	else if requestType = "getValueAtKeyPath" then
		response = processGetValueAtKeyPathRequest(args)
	else if requestType = "getValuesAtKeyPaths" then
		response = processGetValuesAtKeyPathsRequest(args)
	else if requestType = "hasFocus" then
		response = processHasFocusRequest(args)
	else if requestType = "isInFocusChain" then
		response = processIsInFocusChainRequest(args)
	else if requestType = "observeField" then
		response = processObserveFieldRequest(request)
	else if requestType = "setValueAtKeyPath" then
		response = processSetValueAtKeyPathRequest(args)
	else if requestType = "storeNodeReferences" then
		response = processStoreNodeReferencesRequest(args)
	else if requestType = "getNodeReferences" then
		response = processGetNodeReferencesRequest(args)
	else if requestType = "deleteNodeReferences" then
		response = processDeleteNodeReferencesRequest(args)
	else
		response = buildErrorResponseObject("Could not handle request type '" + requestType + "'")
	end if

	if response <> Invalid then
		sendBackResponse(request, response)
	end if
end sub

function processCallFuncRequest(args as Object) as Object
	keyPath = getStringAtKeyPath(args, "keyPath")
	node = processGetValueAtKeyPathRequest(args).value
	if NOT isNode(node) then
		return buildErrorResponseObject("Node not found at key path '" + keyPath + "'")
	end if

	funcName = args.funcName
	if NOT isNonEmptyString(funcName) then
		return buildErrorResponseObject("CallFunc request did not have valid 'funcName' param passed in")
	end if

	p = args.funcParams
	if NOT isNonEmptyArray(p) then p = [Invalid]
	paramsCount = p.count()

	if paramsCount = 1 then
		result = node.callFunc(funcName, p[0])
	else if paramsCount = 2 then
		result = node.callFunc(funcName, p[0], p[1])
	else if paramsCount = 3 then
		result = node.callFunc(funcName, p[0], p[1], p[2])
	else if paramsCount = 4 then
		result = node.callFunc(funcName, p[0], p[1], p[2], p[3])
	else if paramsCount = 5 then
		result = node.callFunc(funcName, p[0], p[1], p[2], p[3], p[4])
	else if paramsCount = 6 then
		result = node.callFunc(funcName, p[0], p[1], p[2], p[3], p[4], p[5])
	else if paramsCount = 7 then
		result = node.callFunc(funcName, p[0], p[1], p[2], p[3], p[4], p[5], p[6])
	end if

	return {
		"value": result
	}
end function

function processGetFocusedNodeRequest(args as Object) as Object
	node = m.top.getScene()
	while true
		child = node.focusedChild
		if child <> Invalid AND NOT node.isSameNode(child) then
			node = child
		else
			exit while
		end if
	end while

	return {
		"node": node
	}
end function

function processGetValueAtKeyPathRequest(args as Object) as Object
	if NOT isNonEmptyString(args.base) then
		args.base = "global"
	end if

	base = getBaseObject(args)
	if base = Invalid then
		return buildErrorResponseObject("Could not handle base type of '" + args.base + "'")
	end if

	keyPath = getStringAtKeyPath(args, "keyPath")

	if keyPath <> "" then
		value = getValueAtKeyPath(base, keyPath, "[[VALUE_NOT_FOUND]]")
		found = NOT isString(value) OR value <> "[[VALUE_NOT_FOUND]]"
	else
		value = base
		found = true
	end if

	return {
		"found": found
		"value": value
	}
end function

function processGetValuesAtKeyPathsRequest(args as Object) as Object
	requests = args.requests
	if NOT isNonEmptyAA(requests) then
		return buildErrorResponseObject("getValuesAtKeyPaths did not have have any requests")
	end if
	response = {}
	for each key in requests
		result = processGetValueAtKeyPathRequest(requests[key])
		if result.value = Invalid then
			return buildErrorResponseObject(result.error.message)
		end if
		response[key] = result.value
	end for
	return response
end function

function processHasFocusRequest(args as Object) as Object
	keyPath = getStringAtKeyPath(args, "keyPath")
	result = processGetValueAtKeyPathRequest(args)

	if result.found <> true then
		return buildErrorResponseObject("No value found at key path '" + keyPath + "'")
	end if

	node = result.value
	if NOT isNode(node) then
		return buildErrorResponseObject("Value at key path '" + keyPath + "' was not a node")
	end if

	return {
		"hasFocus": node.hasFocus()
	}
end function

function processIsInFocusChainRequest(args as Object) as Object
	keyPath = getStringAtKeyPath(args, "keyPath")
	result = processGetValueAtKeyPathRequest(args)

	if result.found <> true then
		return buildErrorResponseObject("No value found at key path '" + keyPath + "'")
	end if

	node = result.value
	if NOT isNode(node) then
		return buildErrorResponseObject("Value at key path '" + keyPath + "' was not a node")
	end if

	return {
		"isInFocusChain": node.isInFocusChain()
	}
end function

function processObserveFieldRequest(request as Object) as Dynamic
	args = request.args
	requestId = request.id
	keyPath = getStringAtKeyPath(args, "keyPath")
	result = processGetValueAtKeyPathRequest(args)
	node = result.value
	field = args.field

	parentIsNode = isNode(node)
	fieldExists = parentIsNode AND node.doesExist(field)
	timePassed = 0
	if NOT parentIsNode OR NOT fieldExists then
		retryTimeout = args.retryTimeout
		if retryTimeout > 0 then
			request.id = request.id
			requestContext = request.context
			if requestContext = Invalid then
				timer = createObject("roSGNode", "Timer")
				timer.duration = args.retryInterval / 1000
				timer.id = requestId
				timer.observeFieldScoped("fire", "onProcessObserveFieldRequestRetryFired")

				requestContext = {
					"timer": timer
					"timespan": createObject("roTimespan")
				}
				request.context = requestContext
				m.activeObserveFieldRequests[requestId] = request
				timer.control = "start"
				return Invalid
			else
				timePassed = requestContext.timespan.totalMilliseconds()
				if timePassed < retryTimeout then
					timer = requestContext.timer
					if timePassed + args.retryInterval > retryTimeout then
						timer.duration = (retryTimeout - timePassed) / 1000
					end if
					timer.control = "start"
					return Invalid
				end if
			end if
		end if

		if NOT parentIsNode then
			errorMessage = "Node not found at key path '" + keyPath + "'"
		else
			errorMessage = "Node did not have field named '" + field + "' at key path '" + keyPath + "'"
		end if
		if timePassed > 0 then
			errorMessage += " timed out after " + timePassed.toStr() + "ms"
		end if
		logWarn(errorMessage)

		m.activeObserveFieldRequests.delete(requestId)
		sendBackResponse(request, buildErrorResponseObject(errorMessage))

		' Might be called asyncronous and we already handled so returning Invalid
		return Invalid
	end if

	' If match was provided, check to see if it already matches the expected value
	match = args.match
	if isAA(match) then
		result = processGetValueAtKeyPathRequest(match)
		if result.found <> true then
			return buildErrorResponseObject("Match was requested and key path was not valid")
		end if
		' TODO build out to support more complicated types
		if result.value = match.value then
			return {
				"value": node[field]
				"observerFired": false
			}
		end if
	end if

	if node.observeFieldScoped(field, "observeFieldCallback") then
		logDebug("Now observing '" + field + "' at key path '" + keyPath + "'")
	else
		return buildErrorResponseObject("Could not observe field '" + field + "' at key path '" + keyPath + "'")
	end if

	request.node = node
	m.activeObserveFieldRequests[requestId] = request
	return Invalid
end function

sub onProcessObserveFieldRequestRetryFired(event as Object)
	requestId = event.getNode()
	request = m.activeObserveFieldRequests[requestId]
	processObserveFieldRequest(request)
end sub

sub observeFieldCallback(event as Object)
	node = event.getRoSgNode()
	field = event.getField()
	data = event.getData()
	logDebug("Received callback for node field '" + field + "' with value ", data)
	for each requestId in m.activeObserveFieldRequests
		request = m.activeObserveFieldRequests[requestId]
		args = request.args
		keyPath = getStringAtKeyPath(args, "keyPath")
		if node.isSameNode(request.node) AND args.field = field then
			match = args.match
			if isAA(match) then
				result = processGetValueAtKeyPathRequest(match)
				if result.found <> true then
					logDebug("Unobserved '" + field + "' at key path '" + keyPath + "'")
					node.unobserveFieldScoped(field)
					m.activeObserveFieldRequests.delete(requestId)
					sendBackResponse(request, buildErrorResponseObject("Match was requested and key path was not valid"))
					return
				end if

				if result.value <> match.value then
					logVerbose("Match.value did not match requested value continuing to wait")
					return
				end if
			end if
			logDebug("Unobserved '" + field + "' at key path '" + keyPath + "'")
			node.unobserveFieldScoped(field)
			m.activeObserveFieldRequests.delete(requestId)
			sendBackResponse(request, {
				"value": data
				"observerFired": true
			})
			return
		end if
	end for
	logError("Received callback for unknown node or field ", node)
end sub

function processSetValueAtKeyPathRequest(args as Object) as Object
	keyPath = getStringAtKeyPath(args, "keyPath")
	result = processGetValueAtKeyPathRequest(args)

	if result.found <> true then
		return buildErrorResponseObject("No value found at key path '" + keyPath + "'")
	end if

	resultValue = result.value
	if NOT isKeyedValueType(resultValue) AND NOT isArray(resultValue) then
		return buildErrorResponseObject("keyPath '" + keyPath + "' can not have a value assigned to it")
	end if

	field = args.field
	if NOT isString(field) then
		return buildErrorResponseObject("Missing valid 'field' param")
	end if

	' Have to walk up the tree until we get to a node as anything that is a field on a node must be replaced
	base = getBaseObject(args)
	nodeParent = resultValue
	parentKeyPath = keyPath
	parentKeyPathParts = parentKeyPath.tokenize(".").toArray()
	setKeyPathParts = []
	while NOT parentKeyPathParts.isEmpty()
		nodeParent = getValueAtKeyPath(base, parentKeyPathParts.join("."))
		if isNode(nodeParent) then
			exit while
		else
			setKeyPathParts.unshift(parentKeyPathParts.pop())
		end if
	end while

	if NOT isNode(nodeParent) then
		nodeParent = base
	end if

	if setKeyPathParts.isEmpty() then
		updateAA = createCaseSensitiveAA(field, args.value)
	else
		setKeyPathParts.push(field)
		nodeFieldKey = setKeyPathParts.shift()
		nodeFieldValueCopy = nodeParent[nodeFieldKey]
		setValueAtKeyPath(nodeFieldValueCopy, setKeyPathParts.join("."), args.value)
		updateAA = createCaseSensitiveAA(nodeFieldKey, nodeFieldValueCopy)
	end if
	nodeParent.update(updateAA, true)
	return {}
end function

function processStoreNodeReferencesRequest(args as Object) as Object
	nodeReferencesKey = args.key

	if NOT isNonEmptyString(nodeReferencesKey) then
		return buildErrorResponseObject("Invalid value supplied for 'key' param")
	end if

	' Reset to avoid keeping things alive across multiple refreshes
	m.nodeReferences[nodeReferencesKey] = []

	allNodes = []
	allNodes.append(m.top.getAll())

	flatTree = []
	' A shortcut to access nodes that were added on the end to reduce iteration/time in those cases by quite a bit
	registers = []
	globalFound = false

	currentNodeReference = 0
	allNodesCount = allNodes.count()
	while currentNodeReference < allNodesCount
		node = allNodes[currentNodeReference]
		parent = node.getParent()
		parentRef = -1

		if parent <> Invalid then
			' First check our registers to see if there is a node we added that might be the parent
			for each potentialParentRef in registers
				potentialParent = allNodes[potentialParentRef]
				if parent.isSameNode(potentialParent) then
					parentRef = potentialParentRef
					exit for
				end if
			end for

			' Tried using while loop and goto but caused device crash so using a bunch of nested ifs instead :(
			if (parentRef < 0) then
				' Next go through the other nodes backwards since parent is usually before the child
				for potentialParentRef = currentNodeReference - 1 to 0 step -1
					potentialParent = allNodes[potentialParentRef]
					if parent.isSameNode(potentialParent) then
						parentRef = potentialParentRef
						exit for
					end if
				end for

				if (parentRef < 0) then
					' Then go through the nodes after this node
					for potentialParentRef = currentNodeReference + 1 to allNodesCount
						potentialParent = allNodes[potentialParentRef]
						if parent.isSameNode(potentialParent) then
							parentRef = potentialParentRef
							exit for
						end if
					end for

					if (parentRef < 0) then
						' If we got all the way to here then we have a "special parent" and need to add it to allNodes and registers
						parentRef = allNodes.count()
						registers.push(parentRef)

						allNodes.push(parent)
						allNodesCount++
					end if
				end if
			end if
		end if

		representation = {
			"id": node.id
			"subtype": node.subtype()
			"ref": currentNodeReference
			"parentRef": parentRef
		}

		if NOT globalFound then
			if m.global.isSameNode(node) then
				representation.global = true
				globalFound = true
			end if
		end if


		flatTree.push(representation)
		currentNodeReference++
	end while

	m.nodeReferences[nodeReferencesKey] = allNodes
	return {
		"flatTree": flatTree
	}
end function

function processGetNodeReferencesRequest(args as Object) as Object
	nodeReferencesKey = args.key
	if NOT isNonEmptyString(nodeReferencesKey) then
		return buildErrorResponseObject("Invalid value supplied for 'key' param")
	end if

	nodeReferences = m.nodeReferences[nodeReferencesKey]
	if NOT isArray(nodeReferences) then
		return buildErrorResponseObject("Invalid key supplied '" + nodeReferencesKey + "'. Make sure you have stored first")
	end if

	requestedNodes = {}
	indexes = getArrayAtKeyPath(args, "indexes")
	if indexes.isEmpty() then
		' Note in bigger apps getting all nodes can create a very large response
		for index = 0 to getLastIndex(nodeReferences)
			indexes.push(index)
		end for
	end if

	for each index in indexes
		node = nodeReferences[index]

		fields = {}
		fieldTypes = node.getFieldTypes()
		for each key in node.getFieldTypes()
			value = node[key]
			fields[key] = {
				"fieldType": fieldTypes[key]
				"type": type(value)
				"value": value
			}
		end for

		requestedNodes[index.toStr()] = {
			"id": node.id
			"subtype": node.subtype()
			"fields": fields
		}
	end for

	return {
		nodes: requestedNodes
	}
end function

function processDeleteNodeReferencesRequest(args as Object) as Object
	nodeReferencesKey = args.key
	if NOT isString(nodeReferencesKey) then
		return buildErrorResponseObject("Invalid value supplied for 'key' param")
	end if
	m.nodeReferences.delete(nodeReferencesKey)

	return {}
end function

function getBaseObject(args as Object) as Dynamic
	baseType = args.base
	if baseType = "global" then return m.global
	if baseType = "scene" then return m.top.getScene()
	if baseType = "nodeRef" then
		return m.nodeReferences[getStringAtKeyPath(args, "key")]
	end if
	return Invalid
end function

sub sendBackResponse(request as Object, response as Object)
	if getBooleanAtKeyPath(request, "args.convertResponseToJsonCompatible", true) then
		response = recursivelyConvertValueToJsonCompatible(response, getNumberAtKeyPath(request, "args.responseMaxChildDepth"))
	end if

	response.id = request.id
	response["timeTaken"] = request.timespan.totalMilliseconds()
	m.task.renderThreadResponse = response
end sub

function recursivelyConvertValueToJsonCompatible(value as Object, maxChildDepth as Integer, depth = 0 as Integer) as Object
	if isArray(value) then
		for i = 0 to getLastIndex(value)
			value[i] = recursivelyConvertValueToJsonCompatible(value[i], maxChildDepth)
		end for
	else if isAA(value) then
		for each key in value
			value[key] = recursivelyConvertValueToJsonCompatible(value[key], maxChildDepth)
		end for
	else if isNode(value) then
		node = value
		value = node.getFields()
		value.delete("focusedChild")
		value.subtype = node.subtype()
		value = recursivelyConvertValueToJsonCompatible(value, maxChildDepth)
		if maxChildDepth > depth then
			children = []
			for each child in node.getChildren(-1, 0)
				children.push(recursivelyConvertValueToJsonCompatible(child, maxChildDepth, depth + 1))
			end for
			value.children = children
		end if
	end if
	return value
end function
