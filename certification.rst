============================
 Certification Requirements
============================

This document details the list of things to check on client's website before allowing them to use our API in production.

---------
 General
---------

The site must send all required HTTP headers with correct values:

	- Content-Type should accurately reflect the sent data's format.
	- Cookie should be unique for all booking sessions, but persistent
	  in each. There must be one cookie per user, and all of a user's search
	  requests must be sent using that cookie. The cookie must be the same
	  in all tabs of one browser.
	- User-Agent should contain an identifier for the client's software.
	  This would preferably be unique to a specific version of what the backend
	  is using to communicate with the Allmyles API, so that the server side
	  can block requests from user agents that are known to misbehave in case
	  of an emergency. (Bad: Java - Good: allmyles-api.py v0.7.2-dev)
	- X-Auth-Token should always contain the client's API token. While there's
	  no way for us to check for this via just clicking through a site, we
	  expect this token to be easily configurable even by someone with little
	  technical experience, to be able to react as quickly as possible if this
	  token is compromised.

- All requests must be relayed through the site's servers, so that the API
  token doesn't get exposed in the browser, as it would if calls were made
  with AJAX request right in the passenger's browser.
- Requests should not be made to a nonexistent endpoint
  (HTTP 404 or HTTP 405), and requests with malformed bodies should be
  avoided as much as possible. If the request fails to validate on the
  Allmyles API, the error's description should be shown to the passenger.

---------
 Flights
---------

- The asynchronous flight search calls should be handled properly as
  described in the documentation; infinite loops must never happen.
- There should be a reasonable amount of time spent sleeping between
  each flight search call for one search.
- Within one client session only one flight search should be going on at
  a time. Parallel periodic requests must not be sent for different flight
  searches. When the processing of a flight search call is
  in progress (Allmyles API is responding with 202) and a new search request
  is submitted with different parameters in the same client session, a HTTP 412
  error will be returned.
- After the Allmyles API returned a status other than 202 with a content body
  in response to a search request, and a new search request with different parameters
  is submitted in the same client session, periodic requesting of the result
  of the previous search should stop. 
- Once the flight result is retrieved once, it shouldn't be requested
  again later in the same workflow.
- Flight details calls must only be made once the passenger has explicitly
  selected one of the results, no prefetching is allowed. (However, making
  multiple details calls in one workflow is allowed.)
- When the retrieved flight details are shown, the flight's updated price
  should be displayed to the passenger. This updated price must be clearly
  visible.
- When the passenger is sent to pay, the amount should match the sum of
  the total price given in the flight details call, and any extra fees
  that the passenger selected, such as for baggages.
- Ticket requests must be made only after payment has been confirmed
  to have been successful. (This is unrelated to the payment call,
  we are referring to the payment from the passenger to the travel site.)
- The passenger's transaction must not be refunded unless the
  Allmyles API explicitly says that it is okay to do so.

------------
 Masterdata
------------

- The number of results retrieved and the number of locales searched
  for a search keyword must be reasonable.
- Masterdata repos should not be retrieved more than once a day.
