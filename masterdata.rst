============
 Masterdata
============

---------
 Summary
---------

The masterdata component consists of the following two endpoints:

 - :ref:`Masterdata_Search` is for general usage; this will search through all
   location data and find appropriate entries for a given keyword, intended
   mostly to be used for autocompleting the location field for users.

 - :ref:`Masterdata_Retrieve` is the call used to retrieve all data of a
   certain type. This should not be used very often---data is cached for 24
   hours, but downloading these once or twice a month should be sufficient.

.. _Masterdata_Search:

--------
 Search
--------

Request
=======

.. http:get:: /masterdata/search

    Searches for locations whose name starts with the provided keyword.

    :GET Parameters:
        - **keyword** -- the string to find locations for
        - **limit** -- *(optional)* the number of results to retrieve
          (default: 10, maximum: 100)
        - **locales** -- *(optional)* the languages to search in in addition to
          English (which is on by default.) Multiple locale codes can be given,
          separated by commas (ex. ``?locales=hu-HU,cs-CZ``) See the available
          locale codes below.

Locale Codes
------------

.. hlist::
    :columns: 3

    - it-IT
    - pl-PL
    - ja-JP
    - es-ES
    - en-GB
    - cs-CZ
    - zh-CN
    - tr-TR
    - ro-RO
    - lt-LT
    - kk-KZ
    - ru-RU
    - hu-HU
    - fr-FR
    - el-GR
    - fi-FI
    - nl-BE
    - hr-HR
    - pt-PT
    - ko-KR
    - sk-SK
    - de-DE
    - sq-AL

Response Body
=============

    :JSON Parameters:
        - **locationSearchResult** (*SearchResult [ ]*) -- root container

          - **canonicalName** -- the complete name of the airport/multiairport
          - **htmlFragment** -- the canonical name, preformatted by bolding
            the searched substring. You can inject this string directly into
            your HTML source.
          - **iataCode** -- the code identifying the matched location---either
            an airport's, or a city's IATA code
          - **category** -- one of the following: airport, multiairport,
            locality, state, country
          - **cityName**
          - **countryCode**
          - **countryName**

Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

      {
        "locationSearchResult": [
          {
            "canonicalName": "Budapest, HU - Liszt Ferenc Intl (BUD)",
            "category": "airport",
            "cityName": "Budapest",
            "countryCode": "HU",
            "countryName": "Hungary",
            "htmlFragment": "<strong>Bud</strong>apest, HU - Liszt Ferenc Intl (<strong>BUD</strong>)",
            "iataCode": "BUD"
          }
        ]
      }

.. _Masterdata_Retrieve:

-----------
 Retrieval
-----------

Request
=======

.. http:get:: /masterdata/:category

  **category** is the data repo you'd like to retrieve. It can be one of the
  following:

  .. hlist::
      :columns: 3

      - airlines
      - airplanes
      - airports
      - categories
      - cities
      - localised_cities
      - countries
      - states
      - hotel_chains
      - hotels
      - rule_links
      - eticket_rules


Response Body
=============

    The response will have a root container that is unique to the requested
    data repo. This is an array, containing objects that are, again, unique.

    .. note::

      A small cosmetic deficiency in the XML output is that the tags of the
      child elements are generated from the root tag, by a not-so-intelligent
      block of word singularizing code. This can lead to things such as a
      <Cities> root containing <Citie> elements. When the root doesn't
      end with the letter S, the XML generator just defaults to calling the
      children <item>s.


Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

      {
        "Airlines": [
          {
            "Active": "true",
            "AirLineCode": "01",
            "AirLineName": "RailEasy",
            "ProviderType": "TravelFusion2Provider"
          },
          {
            "Active": "true",
            "AirLineCode": "08",
            "AirLineName": "Air Southwest",
            "CountryCode": "GB",
            "ProviderType": "ERetailWebFareProvider"
          }
        ]
      }

    **XML:**

    .. sourcecode:: xml

      <Airlines>
        <Airline>
          <Active>true</Active>
          <AirLineCode>ZY</AirLineCode>
          <ProviderType>AmadeusProvider;SkyProvider</ProviderType>
          <AirLineName>Sky Airlines</AirLineName>
        </Airline>
        <Airline>
          <Active>false</Active>
          <AirLineCode>ZZ</AirLineCode>
          <ProviderType>AmadeusProvider</ProviderType>
          <AirLineName>Airline Service</AirLineName>
        </Airline>
      </Airlines>
